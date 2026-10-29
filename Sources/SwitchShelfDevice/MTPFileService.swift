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
            case .albumIndex:
                let indexed = try await AlbumIndexer.collect(stores: stores, transport: opened) { found in
                    await progress(.init(requestID: request.id, phase: "正在查找截图", bytesTransferred: UInt64(found)))
                }
                result.albumEntries = indexed.entries
                result.albumTruncated = indexed.truncated
                result.message = indexed.message
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
                case .storages, .albumIndex: break
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
        case .storages, .albumIndex:
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

/// Read-only screenshot index. It never downloads, uploads, deletes or creates device objects.
private enum AlbumIndexer {
    static let fileLimit = 2_000
    static let depthLimit = 8
    static let objectLimit = 20_000

    struct Result {
        var entries: [MTPFileEntry]
        var truncated: Bool
        var message: String
    }

    private final class State {
        var entries: [MTPFileEntry] = []
        var notes: [String] = []
        var truncated = false
        /// File-count and object-count limits stop the whole walk. Depth does not, so siblings stay visible.
        var stop = false
        var observed = 0
        func note(_ text: String) { if !notes.contains(text) { notes.append(text) } }
        func message(count: Int) -> String {
            var text = count == 0
                ? "没有发现相册截图。只检查 Album、Album (Image SD)、相册工具，以及 SD 卡上的 Nintendo/Album。"
                : "已列出 \(count) 张截图，可以下载到本机。不会删除或修改设备上的文件。"
            if truncated { text += "列表并不完整。" }
            if !notes.isEmpty { text += notes.joined() }
            return text
        }
    }

    static func collect(stores: [MTPFileStoreRecord], transport: any MTPFileTransport,
                        report: @escaping @Sendable (Int) async -> Void) async throws -> Result {
        let state = State()
        let groups = Dictionary(grouping: stores) { MTPFileWorker.key($0.value.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        for store in stores {
            try Task.checkCancellation()
            if state.stop { break }
            let name = store.value.name
            let folded = MTPFileWorker.key(name.trimmingCharacters(in: .whitespacesAndNewlines))
            if groups[folded, default: []].count != 1 {
                state.note("「\(name)」名称不唯一，已跳过。")
                continue
            }
            if MTPFileNames.isAlbumStorage(name) {
                try await walk(store: store, parent: .max, location: MTPFileLocation(storageName: name),
                               transport: transport, state: state, report: report)
            } else if MTPFileNames.isAlbumSDHost(name) {
                try await walkSD(store: store, transport: transport, state: state, report: report)
            }
        }
        let entries = state.entries.sorted {
            let left = $0.modifiedDate ?? "", right = $1.modifiedDate ?? ""
            if left != right { return left > right }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
        return Result(entries: entries, truncated: state.truncated, message: state.message(count: entries.count))
    }

    private static func walkSD(store: MTPFileStoreRecord, transport: any MTPFileTransport,
                               state: State, report: @escaping @Sendable (Int) async -> Void) async throws {
        let root = try await list(store: store, parent: .max, transport: transport, state: state)
        guard !state.stop, let nintendo = uniqueDirectory("Nintendo", in: root, state: state) else { return }
        let inside = try await list(store: store, parent: nintendo.handle, transport: transport, state: state)
        guard !state.stop, let album = uniqueDirectory("Album", in: inside, state: state) else { return }
        try await walk(store: store, parent: album.handle,
                       location: MTPFileLocation(storageName: store.value.name, components: ["Nintendo", "Album"]),
                       transport: transport, state: state, report: report)
    }

    private static func walk(store: MTPFileStoreRecord, parent: UInt32, location: MTPFileLocation,
                             transport: any MTPFileTransport, state: State,
                             report: @escaping @Sendable (Int) async -> Void) async throws {
        if state.stop { return }
        let objects = try await list(store: store, parent: parent, transport: transport, state: state)
        if state.stop { return }
        let grouped = Dictionary(grouping: objects) { MTPFileWorker.key($0.name) }
        for object in objects {
            try Task.checkCancellation()
            if state.stop { return }
            if grouped[MTPFileWorker.key(object.name), default: []].count != 1 {
                state.note("有重名项目无法唯一定位，已跳过。")
                continue
            }
            if object.isDirectory {
                guard location.components.count < depthLimit else {
                    state.truncated = true
                    state.note("目录层级超过 \(depthLimit) 层，列表并不完整。")
                    continue
                }
                try await walk(store: store, parent: object.handle,
                               location: MTPFileLocation(storageName: location.storageName, components: location.components + [object.name]),
                               transport: transport, state: state, report: report)
            } else if MTPFileNames.isScreenshotFile(object.name) {
                guard let bytes = object.byteCount, bytes <= MTPFileUSBTransport.maximumFileBytes else {
                    state.note("有截图缺少可核对的大小，未列入。")
                    continue
                }
                guard state.entries.count < fileLimit else {
                    state.truncated = true
                    state.stop = true
                    state.note("截图数量达到 \(fileLimit) 张上限，列表并不完整。")
                    return
                }
                state.entries.append(.init(location: location, name: object.name, isDirectory: false,
                                           byteCount: bytes, modifiedDate: object.modifiedDate))
                await report(state.entries.count)
            }
        }
    }

    private static func uniqueDirectory(_ name: String, in objects: [MTPFileObjectRecord], state: State) -> MTPFileObjectRecord? {
        let matches = objects.filter { $0.isDirectory && MTPFileWorker.key($0.name) == MTPFileWorker.key(name) }
        if matches.count > 1 {
            state.note("「\(name)」不唯一，已跳过该目录。")
            return nil
        }
        return matches.first
    }

    private static func list(store: MTPFileStoreRecord, parent: UInt32, transport: any MTPFileTransport, state: State) async throws -> [MTPFileObjectRecord] {
        try Task.checkCancellation()
        let handles = try await transport.children(storage: store.handle, parent: parent)
        guard handles.count <= 10_000, Set(handles).count == handles.count else { throw MTPFileError.resourceLimit }
        if state.observed + handles.count > objectLimit {
            state.truncated = true
            state.stop = true
            state.note("目录对象过多，列表在安全上限处停止。")
            return []
        }
        state.observed += handles.count
        var result: [MTPFileObjectRecord] = []
        for handle in handles {
            try Task.checkCancellation()
            let object = try await transport.object(handle)
            let storageMatches = object.storage == store.handle
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
