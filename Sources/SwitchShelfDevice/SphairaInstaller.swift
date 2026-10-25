import Darwin
import Foundation

public enum SphairaInstallError: Error, LocalizedError {
    case busy, exitUnverified, unconfirmed, missingHelper, preparation
    public var errorDescription: String? {
        switch self {
        case .busy: "已有 MTP 安装测试正在进行。"
        case .exitUnverified: "无法确认上次安装进程已退出；已阻止后续发送。不要重试，请检查记录和设备。"
        case .unconfirmed: "必须先核对并明确确认这一个文件和设备端目标位置。"
        case .missingHelper: "应用缺少独立 MTP 安装辅助程序，请重新打包。"
        case .preparation: "无法创建独立且私有的安装记录；未启动传输。"
        }
    }
}

private final class SphairaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private final class SphairaProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var exited = false
    func mark() { lock.lock(); exited = true; lock.unlock() }
    var verified: Bool { lock.lock(); defer { lock.unlock() }; return exited }
    func wait(seconds: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !verified, ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return verified
    }
}

/// At most one callback in flight and one pending update. A blocked UI callback
/// cannot suspend the independent process deadline/cancellation loop.
private final class SphairaProgressDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (SphairaInstallProgress) async -> Void
    private var pending: SphairaInstallProgress?
    private var running = false
    private var stopped = false
    init(_ handler: @escaping @Sendable (SphairaInstallProgress) async -> Void) { self.handler = handler }
    func publish(_ value: SphairaInstallProgress) {
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
    private func take() -> SphairaInstallProgress? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, let value = pending else { running = false; return nil }
        pending = nil; return value
    }
    func stop() { lock.lock(); stopped = true; pending = nil; lock.unlock() }
}

/// Owns exactly one direct child: killing it cannot orphan another USB worker.
/// Cancellation/timeout is not completion until its termination handler proves exit.
public actor SphairaInstaller {
    private let helperURL: URL
    public let recordsURL: URL
    private var busy = false
    private var exitUnverified = false
    public init(helperURL: URL? = nil, recordsURL: URL? = nil) {
        self.helperURL = helperURL ?? (Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/nonexistent")).appendingPathComponent("switchshelf-probe")
        self.recordsURL = recordsURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwitchShelf/MTPInstallAttempts", isDirectory: true)
    }

    public func install(_ request: SphairaInstallRequest, timeoutSeconds: TimeInterval = 7200,
                        stallSeconds: TimeInterval = 120,
                        progress: @escaping @Sendable (SphairaInstallProgress) async -> Void = { _ in }) async throws -> SphairaInstallReport {
        guard !exitUnverified else { throw SphairaInstallError.exitUnverified }
        guard !busy else { throw SphairaInstallError.busy }
        guard request.userConfirmed, UUID(uuidString: request.id) != nil,
              (0.1...14400).contains(timeoutSeconds), (0.1...600).contains(stallSeconds) else {
            throw SphairaInstallError.unconfirmed
        }
        busy = true
        defer { busy = false }
        let helperURL = self.helperURL, recordsURL = self.recordsURL
        let cancellation = SphairaCancellation()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try await Self.supervise(request, helper: helperURL, root: recordsURL, timeout: timeoutSeconds,
                                         stall: stallSeconds, cancellation: cancellation, progress: progress)
            }.value
        } onCancel: { cancellation.cancel() }
        if !result.processExitVerified { exitUnverified = true }
        return result
    }

    private nonisolated static func supervise(_ request: SphairaInstallRequest, helper: URL, root: URL,
        timeout: TimeInterval, stall: TimeInterval, cancellation: SphairaCancellation,
        progress: @escaping @Sendable (SphairaInstallProgress) async -> Void) async throws -> SphairaInstallReport {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: helper.path) else { throw SphairaInstallError.missingHelper }
        let directory = root.appendingPathComponent(request.id, isDirectory: true)
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var rootInfo = stat()
            guard lstat(root.path, &rootInfo) == 0,
                  rootInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), rootInfo.st_uid == geteuid(),
                  chmod(root.path, 0o700) == 0,
                  mkdir(directory.path, 0o700) == 0 else { throw SphairaInstallError.preparation }
            // POSIX mkdir is exclusive: never overwrite a previous request/attempt.
            try SphairaAttemptFile.save(request, at: directory.appendingPathComponent("request.json"))
        } catch { throw SphairaInstallError.preparation }
        let process = Process()
        let token = UUID().uuidString
        process.executableURL = helper
        process.arguments = ["--sphaira-install-worker", token, directory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SWITCHSHELF_INSTALL_TOKEN"] = token
        environment["SWITCHSHELF_INSTALL_PARENT_PID"] = String(getpid())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = SphairaProcessExit()
        process.terminationHandler = { _ in finished.mark() }
        guard !cancellation.isCancelled else { throw CancellationError() }
        do { try process.run() }
        catch { throw SphairaInstallError.missingHelper }

        let delivery = SphairaProgressDelivery(progress)
        defer { delivery.stop() }
        var lastProgress: SphairaInstallProgress?
        let started = ProcessInfo.processInfo.systemUptime
        var lastActivity = started
        var stoppedReason: String?
        var exited = false
        while true {
            if finished.verified { exited = true; break }
            if let value = try? SphairaAttemptFile.load(SphairaInstallProgress.self, at: directory.appendingPathComponent("state.json")),
               value.requestID == request.id, value.totalBytes == request.byteCount,
               value.bytesSubmitted <= request.byteCount, value != lastProgress {
                if let previous = lastProgress, value.bytesSubmitted < previous.bytesSubmitted {
                    stoppedReason = "进度记录不一致"; break
                }
                lastProgress = value; lastActivity = ProcessInfo.processInfo.systemUptime
                delivery.publish(value)
            }
            let now = ProcessInfo.processInfo.systemUptime
            if cancellation.isCancelled { stoppedReason = "已取消"; break }
            if now - started >= timeout || now - lastActivity >= stall { stoppedReason = "传输／来源读取超时"; break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !exited {
            process.terminate()
            if await finished.wait(seconds: 0.5) { exited = true }
            else {
                kill(process.processIdentifier, SIGKILL)
                exited = await finished.wait(seconds: 2)
            }
        }
        var report: SphairaInstallReport
        if exited, stoppedReason == nil,
           let worker = try? SphairaAttemptFile.load(SphairaInstallReport.self, at: directory.appendingPathComponent("worker-result.json")),
           worker.schemaVersion == 1, worker.requestID == request.id,
           worker.transfer.bytesSubmitted <= request.byteCount,
           (worker.transfer.outcome != .notStarted || worker.transfer.bytesSubmitted == 0),
           (worker.transfer.outcome != .transferredAwaitingConfirmation ||
                (worker.transfer.bytesSubmitted == request.byteCount && worker.transfer.failure == nil &&
                 process.terminationStatus == (worker.transfer.releaseVerified ? 0 : 1))) {
            report = .init(schemaVersion: 1, requestID: request.id, transfer: worker.transfer,
                           message: worker.message, processExitVerified: true)
        } else {
            report = .init(schemaVersion: 1, requestID: request.id,
                transfer: .init(outcome: .deviceStateUnknown, bytesSubmitted: lastProgress?.bytesSubmitted ?? 0,
                    failure: cancellation.isCancelled ? .cancelled : .transport, releaseVerified: false),
                message: "\(stoppedReason ?? "辅助程序结果无效")；设备安装状态未知。\(exited ? "辅助进程已退出。" : "无法确认辅助进程退出，已阻止后续发送。")请先核对 sphaira，勿自动重试。",
                processExitVerified: exited)
        }
        do { try SphairaAttemptFile.save(report, at: directory.appendingPathComponent("supervisor-result.json")) }
        catch {
            report = .init(schemaVersion: 1, requestID: request.id,
                transfer: .init(outcome: .deviceStateUnknown, bytesSubmitted: report.transfer.bytesSubmitted,
                    failure: .transport, releaseVerified: report.transfer.releaseVerified),
                message: "安装结果记录失败，状态未知；请核对设备。", processExitVerified: exited)
        }
        return report
    }
}
