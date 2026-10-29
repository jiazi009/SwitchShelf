import Darwin
import Foundation

public enum MTPFileWorker {
    public static func run(_ request: MTPFileRequest, expectedDeviceSignature: String? = nil,
                           progress: @escaping @Sendable (MTPFileProgress) async -> Void = { _ in },
                           partialFile: @escaping @Sendable (MTPFilePartialFile) async throws -> Void = { _ in }) async -> MTPFileResult {
        do {
            let lease = try DeviceLease.acquire()
            defer { lease.release() }
            let verify: @Sendable () async throws -> Void = {
                if [.upload, .download].contains(request.operation), expectedDeviceSignature == nil { throw MTPFileError.invalidRequest }
                guard let expectedDeviceSignature else { return }
                let discovery = await DeviceService().discover()
                let targets = discovery.devices.filter { $0.vendorID == 0x057e && [UInt16(0x201d), 0x3000].contains($0.productID) }
                guard targets.count == 1, targets[0].productID == 0x201d, targets[0].id == expectedDeviceSignature else { throw MTPFileError.changedEntry }
            }
            return await execute(request, verifyDevice: verify, progress: progress, partialFile: partialFile) {
                MTPFileUSBTransport(link: try LibUSBSphairaLink())
            }
        } catch {
            return .init(requestID: request.id, operation: request.operation, outcome: .failed,
                         message: error.localizedDescription)
        }
    }

    /// Cleanup is permitted only after the supervising parent proves direct
    /// worker exit. Never unlinks the requested final destination.
    public static func cleanupDownloadPartial(request: MTPFileRequest, artifact: MTPFilePartialFile) throws {
        guard request.operation == .download, let destination = request.localURL,
              artifact.url.deletingLastPathComponent().path == destination.deletingLastPathComponent().path,
              artifact.url.lastPathComponent.hasPrefix(".SwitchShelf-partial-"),
              UUID(uuidString: String(artifact.url.lastPathComponent.dropFirst(".SwitchShelf-partial-".count))) != nil else { throw MTPFileError.localAccess }
        try MTPFileLocalAccess.validateURL(destination.deletingLastPathComponent())
        let parent = try MTPFileLocalAccess.openDirectory(destination.deletingLastPathComponent().path)
        defer { Darwin.close(parent) }
        var info = stat()
        if fstatat(parent, artifact.url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw MTPFileError.localAccess
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
              info.st_dev == artifact.device, info.st_ino == artifact.inode else { throw MTPFileError.localAccess }
        guard unlinkat(parent, artifact.url.lastPathComponent, 0) == 0 else { throw MTPFileError.localAccess }
    }

    /// Transport injection exists only inside this module for hardware-free
    /// tests. Production run always acquires the shared lease and libusb link.
    static func execute(_ request: MTPFileRequest,
                        verifyDevice: @escaping @Sendable () async throws -> Void = {},
                        progress: @escaping @Sendable (MTPFileProgress) async -> Void = { _ in },
                        partialFile: @escaping @Sendable (MTPFilePartialFile) async throws -> Void = { _ in },
                        makeTransport: @Sendable () async throws -> any MTPFileTransport) async -> MTPFileResult {
        var transport: (any MTPFileTransport)?
        var source: MTPFilePinnedSource?
        var sink: MTPFileDownloadSink?
        var mutationStarted = false
        let counter = MTPFileCounter(requestID: request.id, report: progress)
        do {
            try validate(request)
            try Task.checkCancellation()
            if request.operation == .upload, let reviewed = request.uploadSource {
                source = try MTPFilePinnedSource(reviewed)
            }
            if request.operation == .download, let destination = request.localURL {
                let value = try MTPFileDownloadSink(destination: destination)
                sink = value
                try await partialFile(value.partialFile())
            }
            try await verifyDevice()
            let opened = try await makeTransport()
            transport = opened
            try await opened.open()
            try await verifyDevice()
            var stores = try await opened.storages()
            // A storage name cannot be a stable logical selector when duplicated.
            for index in stores.indices {
                if stores.filter({ key($0.value.name) == key(stores[index].value.name) }).count > 1 {
                    stores[index].value.canUpload = false
                    stores[index].value.role = "入口名称不唯一，只读"
                }
            }
            var result = MTPFileResult(requestID: request.id, operation: request.operation,
                                       outcome: .completed, message: "设备存储入口已读取。")
            switch request.operation {
            case .storages:
                result.storages = stores.map(\.value)
            case .list, .download, .upload:
                guard let location = request.location else { throw MTPFileError.invalidRequest }
                let matches = stores.filter { key($0.value.name) == key(location.storageName) }
                guard matches.count == 1, let store = matches.first else { throw MTPFileError.ambiguousPath }
                let resolver = MTPFileResolver(transport: opened, store: store)
                let parent = try await resolver.resolve(location)
                let objects = try await resolver.list(parent: parent)
                switch request.operation {
                case .list:
                    result.listing = MTPFileListing(location: location, storage: store.value,
                        entries: objects.map { entry($0, location: location) }.sorted {
                            $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory
                        })
                    result.message = "已读取当前目录的 \(objects.count) 项；未递归扫描子目录。"
                case .download:
                    guard let wanted = request.entry, let sink else { throw MTPFileError.invalidRequest }
                    let targets = objects.filter { key($0.name) == key(wanted.name) }
                    guard targets.count == 1, let target = targets.first, !target.isDirectory,
                          let expectedBytes = target.byteCount, expectedBytes == wanted.byteCount,
                          target.modifiedDate == wanted.modifiedDate, expectedBytes <= MTPFileUSBTransport.maximumFileBytes else { throw MTPFileError.changedEntry }
                    try await verifyDevice()
                    await counter.setTotal(expectedBytes)
                    let amount = try await opened.download(target.handle, expectedBytes: expectedBytes) { bytes in
                        try sink.write(bytes)
                        await counter.add(UInt64(bytes.count), phase: "下载中")
                    }
                    guard amount == expectedBytes else { throw MTPFileError.incompleteTransfer }
                    // Re-read metadata in the same session to reject a file changed
                    // while streaming. This still does not claim cryptographic identity.
                    let after = try await opened.object(target.handle)
                    guard after.storage == target.storage, after.parent == target.parent,
                          after.name == target.name, after.byteCount == target.byteCount,
                          after.modifiedDate == target.modifiedDate else { throw MTPFileError.changedEntry }
                    result.transferredBytes = amount
                    result.message = "下载完成；已保存到所选本机位置，未覆盖已有文件。"
                case .upload:
                    guard store.value.canUpload, MTPFileNames.isWritableSD(store.value.name),
                          let source, let reviewed = request.uploadSource else { throw MTPFileError.uploadNotAllowed }
                    guard !objects.contains(where: { key($0.name) == key(reviewed.url.lastPathComponent) }) else { throw MTPFileError.destinationExists }
                    try source.validate()
                    try await verifyDevice()
                    await counter.setTotal(source.byteCount)
                    // As soon as SendObjectInfo can create a placeholder, a failed
                    // or cancelled operation may leave a partial SD object. Never delete it.
                    mutationStarted = true
                    let amount = try await opened.upload(storage: store.handle, parent: parent,
                        name: reviewed.url.lastPathComponent, byteCount: source.byteCount,
                        source: { offset, count in try source.read(offset: offset, count: count) },
                        progress: { bytes in await counter.set(bytes, phase: "上传中") })
                    try source.validate()
                    guard amount == source.byteCount else { throw MTPFileError.incompleteTransfer }
                    result.transferredBytes = amount
                    result.message = "普通文件已上传到 SD 卡；这不是游戏安装。"
                case .storages: break
                }
            }
            try await opened.close()
            transport = nil
            if request.operation == .download, let sink {
                try sink.commit(expectedBytes: result.transferredBytes)
            }
            source?.close()
            return result
        } catch {
            var released = true
            if let transport { do { try await transport.close() } catch { released = false } }
            source?.close()
            let cancelled = error is CancellationError || Task.isCancelled
            let outcome: MTPFileOutcome = mutationStarted ? .deviceStateUnknown : cancelled ? .cancelled : .failed
            let suffix = mutationStarted ? " SD 卡可能留有未完成文件；未删除、覆盖或重试，请在设备端检查。" : ""
            return .init(requestID: request.id, operation: request.operation, outcome: outcome,
                         transferredBytes: await counter.bytes, releaseVerified: released,
                         message: (cancelled ? "文件操作已停止。" : error.localizedDescription) + suffix)
        }
    }
    private static func validate(_ request: MTPFileRequest) throws {
        guard UUID(uuidString: request.id) != nil else { throw MTPFileError.invalidRequest }
        if let location = request.location { try MTPFileNames.validate(location) }
        switch request.operation {
        case .storages:
            guard request.location == nil, request.entry == nil, request.localURL == nil, request.uploadSource == nil else { throw MTPFileError.invalidRequest }
        case .list:
            guard request.location != nil, request.entry == nil, request.localURL == nil, request.uploadSource == nil else { throw MTPFileError.invalidRequest }
        case .download:
            guard let entry = request.entry, entry.location == request.location,
                  !entry.isDirectory, MTPFileNames.isValid(entry.name), request.localURL != nil,
                  let byteCount = entry.byteCount, byteCount <= MTPFileUSBTransport.maximumFileBytes,
                  request.uploadSource == nil else { throw MTPFileError.invalidRequest }
        case .upload:
            guard let location = request.location, MTPFileNames.isWritableSD(location.storageName),
                  request.entry == nil, let source = request.uploadSource, source.url == request.localURL,
                  source.byteCount <= MTPFileUSBTransport.maximumFileBytes,
                  MTPFileNames.isValid(source.url.lastPathComponent),
                  !["nsp", "xci", "nsz", "xcz"].contains(source.url.pathExtension.lowercased()) else { throw MTPFileError.uploadNotAllowed }
            try MTPFileLocalAccess.validateURL(source.url)
        }
    }
    private static func entry(_ object: MTPFileObjectRecord, location: MTPFileLocation) -> MTPFileEntry {
        .init(location: location, name: object.name, isDirectory: object.isDirectory,
              byteCount: object.isDirectory ? nil : object.byteCount, modifiedDate: object.modifiedDate)
    }
    static func key(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

private actor MTPFileCounter {
    let requestID: String
    let report: @Sendable (MTPFileProgress) async -> Void
    var bytes: UInt64 = 0
    var total: UInt64?
    init(requestID: String, report: @escaping @Sendable (MTPFileProgress) async -> Void) {
        self.requestID = requestID; self.report = report
    }
    func setTotal(_ total: UInt64) { self.total = total }
    func add(_ count: UInt64, phase: String) async { bytes += count; await publish(phase) }
    func set(_ count: UInt64, phase: String) async { bytes = count; await publish(phase) }
    private func publish(_ phase: String) async {
        await report(.init(requestID: requestID, phase: phase, bytesTransferred: bytes, totalBytes: total))
    }
}

private actor MTPFileResolver {
    let transport: any MTPFileTransport
    let store: MTPFileStoreRecord
    var observed = 0
    init(transport: any MTPFileTransport, store: MTPFileStoreRecord) { self.transport = transport; self.store = store }
    func resolve(_ location: MTPFileLocation) async throws -> UInt32 {
        var parent = UInt32.max
        for name in location.components {
            let candidates = try await list(parent: parent).filter { MTPFileWorker.key($0.name) == MTPFileWorker.key(name) }
            guard candidates.count == 1, let next = candidates.first, next.isDirectory else { throw MTPFileError.ambiguousPath }
            parent = next.handle
        }
        return parent
    }
    func list(parent: UInt32) async throws -> [MTPFileObjectRecord] {
        try Task.checkCancellation()
        let handles = try await transport.children(storage: store.handle, parent: parent)
        guard handles.count <= 10_000, Set(handles).count == handles.count,
              handles.count <= 20_000 - observed else { throw MTPFileError.resourceLimit }
        observed += handles.count
        var result: [MTPFileObjectRecord] = []
        for handle in handles {
            try Task.checkCancellation()
            let object = try await transport.object(handle)
            let games = store.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "games"
            let storageMatches = object.storage == store.handle || (games && object.storage == UInt32.max - 1)
            let parentMatches = parent == UInt32.max
                ? [UInt32(0), UInt32.max, store.handle].contains(object.parent)
                : object.parent == parent
            guard object.handle == handle, storageMatches, parentMatches,
                  MTPFileNames.isValid(object.name) else { throw MTPFileError.invalidMetadata }
            result.append(object)
        }
        return result
    }
}
