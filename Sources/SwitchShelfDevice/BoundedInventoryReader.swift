import Darwin
import Foundation
import SwitchShelfDomain

/// The sole USB inventory route. Installation uses its own separate worker.
public enum InventoryConnection: String, Sendable, CaseIterable {
    case libusb
}

/// Runs the metadata-only probe in a separate process; native USB calls never
/// block the app. A second request requires the previous process to be proven exited.
public actor BoundedInventoryReader {
    private let probeURL: URL
    private var busy = false
    private var exitUnverified = false

    public init(probeURL: URL? = nil) {
        if let probeURL {
            self.probeURL = probeURL
        } else {
            self.probeURL = (Bundle.main.executableURL?.deletingLastPathComponent()
                ?? URL(fileURLWithPath: "/nonexistent", isDirectory: true))
                .appendingPathComponent("switchshelf-probe")
        }
    }

    public var hasUnverifiedWorker: Bool { exitUnverified }

    public func readInventory(timeoutSeconds: Int = 60, transport: InventoryConnection = .libusb) async throws -> InstalledInventory {
        try Task.checkCancellation()
        guard (1...120).contains(timeoutSeconds) else { throw ProbeError.invalidTimeout }
        guard !exitUnverified else { throw ProbeError.previousProcessUnverified }
        guard !busy else { throw DeviceServiceError(code: .busy, message: "已在读取设备清单；请等待当前只读探测结束。") }
        busy = true
        let url = probeURL
        let cancellation = InventoryCancellation()
        let outcome = await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                Self.run(url: url, seconds: timeoutSeconds, transport: transport, cancellation: cancellation)
            }.value
        } onCancel: { cancellation.cancel() }
        busy = false
        if !outcome.exited { exitUnverified = true; throw ProbeError.previousProcessUnverified }
        try Task.checkCancellation()
        return try outcome.result.get()
    }

    private struct Outcome: Sendable {
        let exited: Bool
        let result: Result<InstalledInventory, ProbeError>
    }

    private struct Response: Decodable {
        let schemaVersion: Int
        let mode: String
        let status: String
        let transport: String?
        let inventory: InstalledInventory?
        let error: Failure?
        struct Failure: Decodable { let code: String; let message: String }
    }

    private nonisolated static func run(url: URL, seconds: Int, transport: InventoryConnection, cancellation: InventoryCancellation) -> Outcome {
        func fail(_ error: ProbeError, exited: Bool = true) -> Outcome {
            Outcome(exited: exited, result: .failure(error))
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return fail(.missingExecutable) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelf-app-probe-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return fail(.temporaryOutput) }
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result.json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let file = try? FileHandle(forWritingTo: output) else { return fail(.temporaryOutput) }
        defer { try? file.close() }

        if cancellation.isCancelled { return fail(.cancelled) }
        let cancelURL = directory.appendingPathComponent("cancel")
        let process = Process()
        process.executableURL = url
        process.arguments = ["inventory", "--transport", transport.rawValue, "--timeout", String(seconds), "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["SWITCHSHELF_PROBE_CANCEL_PATH"] = cancelURL.path
        process.environment = environment
        process.standardOutput = file
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() }
        catch { return fail(.launchFailed) }

        // Cancellation requests go to the supervisor via a private marker. It must
        // reap its USB worker before returning; terminating only the supervisor
        // cannot prove that the worker released the interface.
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds + 3))
        var cancellationDeadline: ContinuousClock.Instant?
        while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
            if cancellation.isCancelled, cancellationDeadline == nil {
                guard FileManager.default.createFile(atPath: cancelURL.path, contents: Data(),
                    attributes: [.posixPermissions: 0o600]) else {
                    process.terminate()
                    if finished.wait(timeout: .now() + .seconds(1)) == .timedOut {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                        _ = finished.wait(timeout: .now() + .seconds(2))
                    }
                    return fail(.previousProcessUnverified, exited: false)
                }
                cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            }
            let now = ContinuousClock.now
            if now >= deadline || cancellationDeadline.map({ now >= $0 }) == true {
                process.terminate()
                if finished.wait(timeout: .now() + .seconds(1)) == .timedOut {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + .seconds(2))
                }
                return fail(.previousProcessUnverified, exited: false)
            }
        }
        guard process.terminationReason == .exit else { return fail(.previousProcessUnverified, exited: false) }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber,
              size.int64Value <= 32 * 1024 * 1024,
              let data = try? Data(contentsOf: output) else { return fail(.invalidResponse, exited: false) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let response = try? decoder.decode(Response.self, from: data),
              response.schemaVersion == 1, response.mode == "inventory" else { return fail(.invalidResponse, exited: false) }
        // An uncertain worker exit must fence retries even if its route claim is inconsistent.
        if response.error?.code == "workerExitUnverified" {
            return fail(.previousProcessUnverified, exited: false)
        }
        guard response.transport == transport.rawValue
        else { return fail(.invalidResponse, exited: false) }
        if response.status == "error" {
            guard [1, 124].contains(process.terminationStatus) else { return fail(.invalidResponse, exited: false) }
            if response.error?.code == "cancelled" { return fail(.cancelled) }
            if response.error?.code == "busy" { return fail(.deviceBusy) }
            if response.error?.code == "accessDeniedOrBusy" { return fail(.sessionUnavailable) }
            return fail(response.error?.code == "timeout" ? .timeout : .readFailed)
        }
        guard let inventory = response.inventory,
              (response.status == "ok" && process.terminationStatus == 0 && inventory.isComplete)
                || (response.status == "partial" && process.terminationStatus == 2 && !inventory.isComplete)
        else { return fail(.invalidResponse, exited: false) }
        return Outcome(exited: true, result: .success(inventory))
    }
}

public enum ProbeError: Error, LocalizedError, Sendable {
    case invalidTimeout, missingExecutable, temporaryOutput, launchFailed
    case cancelled, timeout, readFailed, invalidResponse, previousProcessUnverified, deviceBusy, sessionUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidTimeout: "只读探测超时设置无效。"
        case .missingExecutable: "应用缺少已打包的 switchshelf-probe；请重新安装完整应用。"
        case .temporaryOutput: "无法创建私有探测结果文件；未读取设备。"
        case .launchFailed: "无法启动独立的只读设备探测进程。"
        case .cancelled: "已停止只读清单核对；设备安装结果仍待确认。"
        case .timeout: "只读清单读取超时，完整性未确认；请检查 sphaira / DBI 的 MTP 模式与其他客户端后重试。"
        case .readFailed: "只读设备探测失败；清单保持未知，请检查 sphaira / DBI 的 MTP 模式和连接。"
        case .invalidResponse: "只读探测返回无效或不一致的结果；清单保持未知。"
        case .previousProcessUnverified: "无法确认上次探测进程已退出；为避免并发访问设备，请重启应用后再试。"
        case .deviceBusy: "另一个进程正在使用 Switch USB 会话（例如 Backend 传输）；请等待该操作结束后重试。"
        case .sessionUnavailable: "MTP 会话无法打开，可能被其他客户端占用或权限不足。请退出 OpenMTP，并保持 sphaira / DBI 的 MTP 开启后重试。"
        }
    }
}

/// Cancellation is sampled on the detached supervisor thread; no Process crosses
/// isolation domains and the actor remains busy until child exit is verified.
private final class InventoryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
