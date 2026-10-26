import Darwin
import Foundation
import SwitchShelfBackend

/// One-shot reviewed Backend attempt: local preflight, allowlisted range reader,
/// shared device lease, explicit native open, protocol session, durable journal.
///
/// This runner never selects an install destination on the device and cannot
/// confirm installation. Device-side selection and completion remain user-visible
/// facts that must be recorded separately.
public enum BackendInstallRunner {
    public static func run(_ request: BackendInstallRequest,
                           provider: any BackendInstallTransportProviding) async -> BackendInstallReport {
        let startedAt = Date()
        var notes: [String] = []
        let fileName = request.fileURL.lastPathComponent
        var byteCount: UInt64 = 0

        func report(_ outcome: BackendInstallOutcome, _ message: String,
                    attemptID: UUID? = nil, journalState: String? = nil,
                    transfer: BackendTransferResult? = nil) -> BackendInstallReport {
            BackendInstallReport(outcome: outcome, message: message, fileName: fileName,
                                 filePath: request.fileURL.path, byteCount: byteCount,
                                 uniqueBytesSent: transfer?.totalBytesSent ?? 0,
                                 peerRequestedExit: transfer?.peerRequestedExit ?? false,
                                 attemptID: attemptID?.uuidString,
                                 journalPath: request.journalURL.path,
                                 journalState: journalState,
                                 startedAt: startedAt, finishedAt: Date(), notes: notes)
        }

        guard request.fileURL.isFileURL,
              request.fileURL.path.hasPrefix("/"),
              !request.fileURL.path.split(separator: "/").contains("..") else {
            notes.append("请求路径必须是绝对路径且不含 ..。")
            return report(.failed, "请求路径无效；未访问设备。")
        }
        guard (30...7_200).contains(request.sessionTimeoutSeconds) else {
            notes.append("会话超时必须介于 30 与 7200 秒。")
            return report(.failed, "会话超时设置无效；未访问设备。")
        }
        guard (1...1_048_576).contains(request.maximumChunkSize) else {
            notes.append("分块大小必须介于 1 与 1,048,576 字节。")
            return report(.failed, "分块大小无效；未访问设备。")
        }
        guard (1...60_000).contains(Int(request.operationTimeoutMilliseconds)) else {
            notes.append("单次 I/O 超时必须介于 1 与 60,000 毫秒。")
            return report(.failed, "I/O 超时设置无效；未访问设备。")
        }

        var info = stat()
        guard lstat(request.fileURL.path, &info) == 0 else {
            notes.append("无法读取源文件元数据：\(String(cString: strerror(errno)))。")
            return report(.failed, "源文件不存在或无法访问；未访问设备。")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size > 0 else {
            notes.append("源文件必须是可读的普通文件且大小大于 0。")
            return report(.failed, "源文件类型或大小无效；未访问设备。")
        }
        byteCount = UInt64(info.st_size)

        let entry = BackendPreflightEntry(id: "backend-install-source", name: fileName,
                                          expectedBytes: Int64(byteCount), included: true,
                                          sourceURL: request.fileURL, sourceAvailable: true,
                                          snapshotBytes: Int64(byteCount))
        let input = BackendPreflightInput(items: [
            BackendPreflightItem(id: "backend-install-request",
                                 intendedTarget: request.intendedTarget,
                                 entries: [entry])
        ])
        let prepared = BackendPreflight.check(input)
        guard prepared.isPrepared, let offer = prepared.offers.first else {
            let text = prepared.issues.map(\.message).joined(separator: " ")
            notes.append(contentsOf: prepared.issues.map(\.message))
            return report(.failed, text.isEmpty ? "本地预检未通过；未访问设备。" : text)
        }

        let reader: AllowlistedBackendFileReader
        do {
            reader = try await AllowlistedBackendFileReader.open(bindings: [
                BackendSourceBinding(id: offer.id, url: request.fileURL, expectedBytes: offer.byteCount)
            ])
        } catch {
            return report(.failed, "源文件绑定失败：\(message(of: error))；未访问设备。")
        }

        let journal: BackendTransferJournal
        do {
            journal = try await BackendTransferJournal.open(at: request.journalURL)
        } catch {
            return report(.journalUnavailable, "无法打开传输记录：\(message(of: error))；未访问设备。")
        }
        let attemptID = UUID()
        do {
            try await journal.begin(id: attemptID, offers: [offer])
        } catch {
            return report(.journalUnavailable, "无法开始传输记录：\(message(of: error))；未访问设备。")
        }

        let transport: any BackendByteTransport
        do {
            transport = try await provider.makeTransport()
        } catch {
            try? await journal.end(attemptID: attemptID, state: .failed)
            let state = await journalState(of: journal)
            let outcome = mapOpenError(error)
            return report(outcome, "无法打开 Backend USB 会话：\(message(of: error))；未开始传输。",
                          attemptID: attemptID, journalState: state)
        }

        let options = BackendSessionOptions(operationTimeoutMilliseconds: request.operationTimeoutMilliseconds,
                                            sessionTimeoutMilliseconds: UInt32(request.sessionTimeoutSeconds * 1_000),
                                            maximumCommandPayload: 65_536,
                                            maximumChunkSize: request.maximumChunkSize,
                                            maximumCommands: 100_000)
        let session = BackendSession(transport: transport, reader: reader, options: options)
        let observer: BackendProgressObserver = { snapshot in
            try await journal.record(snapshot, attemptID: attemptID)
            let totalBytes = snapshot.files.reduce(UInt64(0)) { $0 + $1.byteCount }
            request.progress?(snapshot.totalBytesSent, totalBytes)
        }

        let transfer: BackendTransferResult
        do {
            transfer = try await session.run(offers: [offer], onProgress: observer)
        } catch let journalError as BackendJournalError {
            let state = await journalState(of: journal)
            return report(.journalUnavailable,
                          "进度落盘失败，会话已中止：\(String(describing: journalError))；设备安装结果未知。",
                          attemptID: attemptID, journalState: state)
        } catch {
            let cancelled = error is CancellationError || (error as? BackendError) == .cancelled
            try? await journal.end(attemptID: attemptID, state: cancelled ? .interrupted : .failed)
            let state = await journalState(of: journal)
            let outcome: BackendInstallOutcome = cancelled ? .cancelled : (isIncomplete(error) ? .incompleteTransfer : .failed)
            return report(outcome, "Backend 会话失败：\(message(of: error))；设备安装结果未知。",
                          attemptID: attemptID, journalState: state)
        }

        do {
            try await journal.record(transfer, attemptID: attemptID)
            try await journal.end(attemptID: attemptID, state: .finished)
        } catch {
            notes.append("最终传输记录未能落盘：\(message(of: error))")
            let state = await journalState(of: journal)
            return report(.journalUnavailable,
                          "设备已请求 EXIT，但最终传输记录落盘失败；主机侧证据不完整，安装结果未知。",
                          attemptID: attemptID, journalState: state, transfer: transfer)
        }

        let complete = transfer.files.allSatisfy { $0.phase == .transferredAwaitingConfirmation }
        let outcome: BackendInstallOutcome = complete ? .transferredAwaitingConfirmation : .incompleteTransfer
        let message = complete
            ? "主机已完整发送设备请求的全部字节，且设备请求了 EXIT；这不等于安装成功，安装结果需在设备端确认。"
            : "设备请求了 EXIT，但主机侧覆盖不完整；安装结果未知。"
        let state = await journalState(of: journal)
        return report(outcome, message, attemptID: attemptID, journalState: state, transfer: transfer)
    }

    private static func journalState(of journal: BackendTransferJournal) async -> String? {
        let attempts = await journal.attempts()
        return attempts.last?.state.rawValue
    }

    private static func mapOpenError(_ error: Error) -> BackendInstallOutcome {
        guard let backendError = error as? BackendError else { return .failed }
        switch backendError {
        case .busy: return .deviceBusy
        case .unavailable, .releaseUnverified: return .deviceUnavailable
        default: return .failed
        }
    }

    private static func isIncomplete(_ error: Error) -> Bool {
        guard let backendError = error as? BackendError else { return false }
        switch backendError {
        case .timeout, .disconnected, .transport: return true
        default: return false
        }
    }

    private static func message(of error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
