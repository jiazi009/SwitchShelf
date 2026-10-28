import Foundation

/// Only the token-gated direct child executable invokes the production entry point.
/// Tests inject a transport factory; bad requests/journal failures precede lease/open.
public enum SphairaInstallWorker {
    public static func run(directory: URL) async -> SphairaInstallReport {
        do {
            let request = try SphairaAttemptFile.load(SphairaInstallRequest.self, at: directory.appendingPathComponent("request.json"))
            return await execute(request: request, directory: directory, leaseURL: DeviceLease.defaultURL) {
                NativeSphairaMTP(link: try LibUSBSphairaLink())
            }
        } catch {
            return report(id: "invalid", result: .init(outcome: .notStarted, bytesSubmitted: 0,
                failure: .invalidRequest, releaseVerified: true), message: "安装请求无效；未访问 USB。")
        }
    }

    static func execute(request: SphairaInstallRequest, directory: URL, leaseURL: URL,
                        busyInterval: Duration = .seconds(3), busyAttempts: Int = 200,
                        makeTransport: @Sendable () async throws -> any SphairaUploadTransport) async -> SphairaInstallReport {
        var source: SphairaPackageSource?
        var completedResult: SphairaUploadResult?
        do {
            try request.validate()
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path) else {
                return report(id: request.id, result: .init(outcome: .notStarted, bytesSubmitted: 0,
                    failure: .invalidRequest, releaseVerified: true), message: "已有尝试记录已保留，禁止重复执行此请求。")
            }
            let openedSource = try SphairaPackageSource(url: request.sourceURL, allowedRoot: request.allowedRoot,
                expectedBytes: request.byteCount, reviewedIdentity: request.identity)
            source = openedSource
            try await openedSource.validate()
            let journal = SphairaWorkerJournal(directory: directory, request: request)
            try await journal.update(bytes: 0, phase: "opening")
            let lease = try DeviceLease.acquire(at: leaseURL)
            defer { lease.release() }
            // Sphaira returns PTP Device Busy (0x2019) while it is still installing the
            // previous file. That refusal sends nothing. Wait for the same file, then
            // open a new session. A transfer that already submitted bytes is never repeated.
            var result: SphairaUploadResult?
            var attempt = 0
            while attempt < max(1, busyAttempts) {
                try Task.checkCancellation()
                attempt += 1
                do {
                    let transport = try await makeTransport()
                    let uploaded = await SphairaMTPUpload().upload(name: request.name, from: openedSource, through: transport) { bytes in
                        try await journal.update(bytes: bytes, phase: "transferring")
                    }
                    result = uploaded
                    let deviceIsBusy = uploaded.failure == .deviceBusy && uploaded.bytesSubmitted == 0
                    guard deviceIsBusy, attempt < busyAttempts else { break }
                } catch {
                    guard result?.failure == .deviceBusy, result?.bytesSubmitted == 0, attempt < busyAttempts else { throw error }
                }
                try await journal.update(bytes: 0, phase: "waiting")
                try await Task.sleep(for: busyInterval)
            }
            guard let result else { throw SphairaUploadError.invalidResponse }
            completedResult = result
            await openedSource.close()
            let message: String
            if result.outcome == .transferredAwaitingConfirmation {
                message = "文件传输已获 MTP 确认，等待核对 sphaira 安装结果；这不代表已安装。"
            } else if result.failure == .deviceBusy {
                message = "设备仍在安装上一份文件，这一份还没有发送。请等 Switch 显示完成后再继续。设备返回 PTP 错误 0x2019。"
            } else if result.outcome == .notStarted {
                message = "未开始发送游戏包。请检查 sphaira 模式、文件和连接。"
            } else {
                message = "传输未确认完成，设备状态未知。请查看 sphaira；不要自动重试或删除设备对象。"
            }
            let report = report(id: request.id, result: result,
                message: message + (result.detail.map { " " + $0 } ?? ""))
            try SphairaAttemptFile.save(report, at: directory.appendingPathComponent("worker-result.json"))
            return report
        } catch {
            if let source { await source.close() }
            let message: String
            if completedResult != nil { message = "结果日志写入失败，安装状态未知；请核对设备，勿自动重试。" }
            else if let error = error as? SphairaNativeError { message = error.localizedDescription }
            else if let error = error as? DeviceLeaseError { message = error.localizedDescription }
            else { message = "确认信息、源文件或日志准备失败，未发送游戏包。请重新检查来源和本地记录。" }
            let report = report(id: request.id, result: .init(outcome: completedResult == nil ? .notStarted : .deviceStateUnknown,
                bytesSubmitted: completedResult?.bytesSubmitted ?? 0, failure: .invalidRequest,
                releaseVerified: completedResult?.releaseVerified ?? true), message: message)
            try? SphairaAttemptFile.save(report, at: directory.appendingPathComponent("worker-result.json"))
            return report
        }
    }

    static func report(id: String, result: SphairaUploadResult, message: String) -> SphairaInstallReport {
        .init(schemaVersion: 1, requestID: id, transfer: result, message: message, processExitVerified: false)
    }
}

private actor SphairaWorkerJournal {
    let directory: URL
    let request: SphairaInstallRequest
    private var lastSave = Date.distantPast
    init(directory: URL, request: SphairaInstallRequest) { self.directory = directory; self.request = request }
    func update(bytes: UInt64, phase: String) throws {
        // Persist first side-effect intent unconditionally; then throttle checkpoint I/O.
        if bytes != 0, bytes != request.byteCount, Date().timeIntervalSince(lastSave) < 0.25 { return }
        let progress = SphairaInstallProgress(requestID: request.id, phase: phase,
            bytesSubmitted: bytes, totalBytes: request.byteCount, updatedAt: .now)
        try SphairaAttemptFile.save(progress, at: directory.appendingPathComponent("state.json"))
        lastSave = .now
    }
}
