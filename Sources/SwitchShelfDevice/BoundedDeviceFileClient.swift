import Darwin
import Foundation

public enum DeviceFileClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest, busy, missingHelper, preparation, launchFailed
    case cancelled, timeout, invalidResponse, unverifiedWorker
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "文件操作缺少有效请求或当前 USB 会话；未启动传输。"
        case .busy: "设备文件操作正在进行，请等待完成或取消。"
        case .missingHelper: "应用缺少设备文件辅助程序，请重新安装完整应用。"
        case .preparation: "无法准备私有文件操作记录；未访问设备。"
        case .launchFailed: "设备文件辅助程序无法启动；未访问设备。"
        case .cancelled: "文件操作已取消。若正在上传，设备可能保留未完成文件；不会自动重试或删除。"
        case .timeout: "设备文件操作超时，已停止辅助进程。若正在上传，设备文件状态待确认。"
        case .invalidResponse: "设备文件操作返回无效结果；未确认完成，不会自动重试。"
        case .unverifiedWorker: "无法确认辅助进程退出或连接释放，已阻止后续设备操作；请重启应用后检查连接。"
        }
    }
}

/// One direct helper owns all file I/O and USB work. A client request never
/// opens USB on the app's cooperative executor and never leaves a grandchild.
public actor BoundedDeviceFileClient {
    private let helperURL: URL
    private var busy = false
    private var fenced = false
    public init(helperURL: URL? = nil) {
        self.helperURL = helperURL ?? (Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/nonexistent", isDirectory: true)).appendingPathComponent("switchshelf-probe")
    }
    public var hasUnverifiedWorker: Bool { fenced }
    public var isBusy: Bool { busy }

    public func execute(_ request: MTPFileRequest, expectedDeviceSignature: String? = nil,
                        timeoutSeconds: TimeInterval = 120,
                        progress: @escaping @Sendable (MTPFileProgress) async -> Void = { _ in }) async throws -> MTPFileResult {
        try Task.checkCancellation()
        guard !fenced else { throw DeviceFileClientError.unverifiedWorker }
        guard !busy else { throw DeviceFileClientError.busy }
        guard UUID(uuidString: request.id) != nil, (0.1...14_400).contains(timeoutSeconds),
              ![MTPFileOperation.upload, .download].contains(request.operation) ||
                expectedDeviceSignature?.hasPrefix("usb-registry-") == true else { throw DeviceFileClientError.invalidRequest }
        busy = true
        defer { busy = false }
        let cancellation = DeviceFileCancellation()
        let url = helperURL
        let envelope = DeviceFileProcessRequest(request: request, expectedDeviceSignature: expectedDeviceSignature)
        let result = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                Self.supervise(envelope, helper: url, timeout: timeoutSeconds, cancellation: cancellation, progress: progress)
            }.value
        } onCancel: { cancellation.cancel() }
        if !result.exitVerified { fenced = true; throw DeviceFileClientError.unverifiedWorker }
        if result.fence { fenced = true }
        if case .success(let value) = result.result, !value.releaseVerified { fenced = true }
        // Process ownership is settled before cancellation is delivered to the UI.
        try Task.checkCancellation()
        let value = try result.result.get()
        return value
    }

    private struct SupervisedResult: Sendable {
        var exitVerified = true
        var fence = false
        var result: Result<MTPFileResult, DeviceFileClientError>
    }
    private nonisolated static func supervise(_ envelope: DeviceFileProcessRequest, helper: URL,
        timeout: TimeInterval, cancellation: DeviceFileCancellation,
        progress: @escaping @Sendable (MTPFileProgress) async -> Void) -> SupervisedResult {
        func failure(_ error: DeviceFileClientError, exited: Bool = true, fence: Bool = false) -> SupervisedResult {
            .init(exitVerified: exited, fence: fence, result: .failure(error))
        }
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return failure(.missingHelper) }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("SwitchShelf-file-op-\(UUID().uuidString)", isDirectory: true)
        do {
            guard mkdir(root.path, 0o700) == 0 else { throw DeviceFileClientError.preparation }
            try DeviceFileProcessIO.save(envelope, at: root.appendingPathComponent("request.json"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            return failure(.preparation)
        }
        var exitSettled = true
        // Preserve the cancellation marker and private evidence if a child cannot
        // be proven exited; deleting its directory is not an ownership release.
        defer {
            if exitSettled {
                if envelope.request.operation == .download,
                   let artifact = try? DeviceFileProcessIO.load(MTPFilePartialFile.self,
                    at: root.appendingPathComponent("partial.json"), limit: 65_536) {
                    // Core validates parent, exact private inode/device and ownership.
                    // It can only remove the temporary receipt, never the final target.
                    try? MTPFileWorker.cleanupDownloadPartial(request: envelope.request, artifact: artifact)
                }
                try? FileManager.default.removeItem(at: root)
            }
        }
        if cancellation.isCancelled { return failure(.cancelled) }
        let process = Process()
        let token = UUID().uuidString
        process.executableURL = helper
        process.arguments = ["--device-file-worker", token, root.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SWITCHSHELF_DEVICE_FILE_TOKEN"] = token
        environment["SWITCHSHELF_DEVICE_FILE_PARENT_PID"] = String(getpid())
        environment["SWITCHSHELF_DEVICE_FILE_TIMEOUT"] = String(Int(ceil(timeout)) + 3)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return failure(.launchFailed) }
        exitSettled = false
        let relay = DeviceFileProgressDelivery(progress)
        defer { relay.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var lastProgress: MTPFileProgress?
        var interruption: DeviceFileClientError?
        while exited.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if let value = try? DeviceFileProcessIO.load(MTPFileProgress.self, at: root.appendingPathComponent("progress.json"), limit: 65_536),
               value.requestID == envelope.request.id, value != lastProgress,
               value.totalBytes.map({ value.bytesTransferred <= $0 }) ?? true {
                if let previous = lastProgress, value.bytesTransferred < previous.bytesTransferred {
                    interruption = .invalidResponse; break
                }
                lastProgress = value
                relay.publish(value)
            }
            if cancellation.isCancelled { interruption = .cancelled; break }
            if ContinuousClock.now >= deadline { interruption = .timeout; break }
        }
        if let interruption {
            // Give the direct worker a brief cooperative cancellation opportunity,
            // then bound native/SMB stalls by terminating and reaping that same child.
            try? DeviceFileProcessIO.save(true, at: root.appendingPathComponent("cancel"))
            var forcedTermination = false
            if exited.wait(timeout: .now() + .milliseconds(300)) == .timedOut {
                forcedTermination = true
                process.terminate()
                if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    guard exited.wait(timeout: .now() + .seconds(2)) == .success else {
                        return failure(.unverifiedWorker, exited: false, fence: true)
                    }
                }
            }
            exitSettled = true
            // OS exit proves host ownership ended, but killing a streaming USB
            // phase does not establish a clean protocol handoff. Only a matching
            // cooperative result can authorize later file/inventory/install work.
            let cooperative = !forcedTermination && process.terminationReason == .exit
                ? (try? DeviceFileProcessIO.load(DeviceFileProcessResponse.self,
                    at: root.appendingPathComponent("result.json"), limit: 16 * 1024 * 1024)) : nil
            let releaseConfirmed = cooperative?.schemaVersion == 1 && cooperative?.requestID == envelope.request.id &&
                cooperative?.result?.requestID == envelope.request.id && cooperative?.result?.operation == envelope.request.operation &&
                cooperative?.result?.releaseVerified == true &&
                process.terminationStatus == (cooperative?.result?.outcome == .completed ? 0 : 1)
            return failure(interruption, fence: interruption == .invalidResponse || !releaseConfirmed)
        }
        exitSettled = true
        // A direct child's observed exit settles OS ownership even after a signal.
        // A signal or missing/mismatched report cannot establish transfer completion.
        guard process.terminationReason == .exit,
              let response = try? DeviceFileProcessIO.load(DeviceFileProcessResponse.self, at: root.appendingPathComponent("result.json"), limit: 16 * 1024 * 1024),
              response.schemaVersion == 1, response.requestID == envelope.request.id else {
            return failure(.invalidResponse, fence: true)
        }
        guard let value = response.result, value.requestID == envelope.request.id,
              value.operation == envelope.request.operation,
              (value.outcome == .completed && value.releaseVerified && process.terminationStatus == 0) ||
                (value.outcome != .completed && process.terminationStatus == 1) ||
                (value.outcome == .completed && !value.releaseVerified && process.terminationStatus == 1) else {
            return failure(.invalidResponse, fence: true)
        }
        return .init(result: .success(value))
    }
}

private struct DeviceFileProcessRequest: Codable, Sendable {
    var schemaVersion = 1
    let request: MTPFileRequest
    let expectedDeviceSignature: String?
}
private struct DeviceFileProcessResponse: Codable, Sendable {
    var schemaVersion = 1
    let requestID: String
    let result: MTPFileResult?
    let error: String?
}

/// The token-gated probe entry point calls this only in its direct child. The
/// caller authenticates the parent; this layer validates private files before USB.
public enum DeviceFileProcessWorker {
    public static func run(directory: URL) async -> Int32 {
        let parentPID = getppid()
        do {
            try DeviceFileProcessIO.validateDirectory(directory)
            let envelope = try DeviceFileProcessIO.load(DeviceFileProcessRequest.self,
                at: directory.appendingPathComponent("request.json"), limit: 1_048_576)
            guard envelope.schemaVersion == 1, UUID(uuidString: envelope.request.id) != nil,
                  ![MTPFileOperation.upload, .download].contains(envelope.request.operation) ||
                    envelope.expectedDeviceSignature?.hasPrefix("usb-registry-") == true else {
                throw DeviceFileClientError.invalidRequest
            }
            let journal = DeviceFileProgressJournal(url: directory.appendingPathComponent("progress.json"))
            let operation = Task {
                await MTPFileWorker.run(envelope.request, expectedDeviceSignature: envelope.expectedDeviceSignature,
                    progress: { value in
                        await journal.publish(value)
                    }, partialFile: { artifact in
                        try DeviceFileProcessIO.save(artifact, at: directory.appendingPathComponent("partial.json"))
                    })
            }
            let watcher = Task.detached {
                while !Task.isCancelled {
                    if getppid() != parentPID { Darwin._exit(1) }
                    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancel").path) {
                        operation.cancel()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let result = await operation.value
            watcher.cancel()
            await watcher.value
            await journal.finish(result)
            try DeviceFileProcessIO.save(DeviceFileProcessResponse(requestID: envelope.request.id, result: result, error: nil),
                at: directory.appendingPathComponent("result.json"))
            return result.outcome == .completed && result.releaseVerified ? 0 : 1
        } catch {
            // A failed private-request check never enters the core USB worker.
            return 1
        }
    }
}

/// Streaming callbacks can arrive every 64 KiB. Persist at most four ordinary
/// progress updates per second while retaining the first, phase changes and final bytes.
actor DeviceFileProgressJournal {
    private let write: @Sendable (MTPFileProgress) throws -> Void
    private var latest: MTPFileProgress?
    private var writtenPhase: String?
    private var lastWrite: ContinuousClock.Instant?
    init(url: URL) { write = { try DeviceFileProcessIO.save($0, at: url) } }
    init(write: @escaping @Sendable (MTPFileProgress) throws -> Void) { self.write = write }
    func publish(_ value: MTPFileProgress) {
        persist(value, force: false)
    }
    func finish(_ result: MTPFileResult) {
        persist(.init(requestID: result.requestID, phase: result.outcome == .completed ? "已完成" : "已停止",
            bytesTransferred: result.transferredBytes, totalBytes: latest?.totalBytes), force: true)
    }
    private func persist(_ value: MTPFileProgress, force: Bool) {
        latest = value
        let now = ContinuousClock.now
        guard force || lastWrite == nil || writtenPhase != value.phase ||
                value.totalBytes.map({ value.bytesTransferred >= $0 }) == true ||
                lastWrite.map({ $0.duration(to: now) >= .milliseconds(250) }) == true else { return }
        // Even a filesystem error must not turn every streaming callback into a
        // fresh atomic-write attempt; the final result has independent persistence.
        lastWrite = now
        writtenPhase = value.phase
        try? write(value)
    }
}

private enum DeviceFileProcessIO {
    static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/"),
              url.resolvingSymlinksInPath().path == url.path,
              lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw DeviceFileClientError.preparation }
    }
    static func load<T: Decodable>(_ type: T.Type, at url: URL, limit: Int) throws -> T {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw DeviceFileClientError.preparation }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= limit else { throw DeviceFileClientError.preparation }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = pread(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw DeviceFileClientError.preparation }
                offset += n
            }
        }
        return try JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, at url: URL) throws {
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw DeviceFileClientError.preparation }
    }
}
private final class DeviceFileCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
/// Bounded latest-value relay: a slow UI callback cannot delay process deadlines.
private final class DeviceFileProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (MTPFileProgress) async -> Void
    private var pending: MTPFileProgress?
    private var running = false
    private var stopped = false
    init(_ handler: @escaping @Sendable (MTPFileProgress) async -> Void) { self.handler = handler }
    func publish(_ value: MTPFileProgress) {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        pending = value
        let start = !running
        running = true
        lock.unlock()
        if start {
            Task.detached { [self] in
                while let value = take() { await handler(value) }
            }
        }
    }
    private func take() -> MTPFileProgress? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let value = pending else { running = false; return nil }
        pending = nil
        return value
    }
    func stop() { lock.lock(); stopped = true; pending = nil; lock.unlock() }
}
