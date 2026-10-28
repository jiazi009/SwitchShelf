import Foundation

public struct SphairaBatchItem: Sendable, Identifiable {
    public let gameTitle: String
    public let request: SphairaInstallRequest
    public var id: String { request.id }
    public init(gameTitle: String, request: SphairaInstallRequest) {
        self.gameTitle = gameTitle; self.request = request
    }
}

public struct SphairaBatchReview: Sendable, Identifiable {
    public let id = UUID()
    public let items: [SphairaBatchItem]
    public init(items: [SphairaBatchItem]) { self.items = items }
    public var totalBytes: UInt64 {
        items.reduce(0) { total, item in
            let (sum, overflow) = total.addingReportingOverflow(item.request.byteCount)
            return overflow ? .max : sum
        }
    }
}

public struct SphairaBatchStatus: Sendable, Identifiable {
    public var id: String { item.id }
    public enum State: Sendable {
        case waiting, sending, transferred, stopped(String)
    }
    public let item: SphairaBatchItem
    public var state: State
    public var bytesSubmitted: UInt64
    public var phase: String
    public init(item: SphairaBatchItem, state: State, bytesSubmitted: UInt64, phase: String = "") {
        self.item = item
        self.state = state
        self.bytesSubmitted = bytesSubmitted
        self.phase = phase
    }
}

/// Serial orchestration; every request remains protected by the existing isolated worker.
public enum SphairaBatchInstaller {
    public typealias Sender = @Sendable (SphairaInstallRequest, @escaping @Sendable (SphairaInstallProgress) async -> Void) async throws -> SphairaInstallReport
    public enum Event: Sendable {
        case statuses([SphairaBatchStatus])
        case progress(requestID: String, bytesSubmitted: UInt64, phase: String)
    }
    public typealias Observer = @Sendable (Event) async -> Void

    public static func run(_ items: [SphairaBatchItem], send: @escaping Sender,
                           observe: @escaping Observer) async {
        var statuses = items.map { SphairaBatchStatus(item: $0, state: .waiting, bytesSubmitted: 0) }
        await observe(.statuses(statuses))
        for index in items.indices {
            guard !Task.isCancelled else { break }
            statuses[index].state = .sending
            await observe(.statuses(statuses))
            do {
                let report = try await send(items[index].request.confirmed()) { progress in
                    await observe(.progress(requestID: progress.requestID, bytesSubmitted: progress.bytesSubmitted, phase: progress.phase))
                }
                statuses[index].bytesSubmitted = report.transfer.bytesSubmitted
                if report.transfer.outcome == .transferredAwaitingConfirmation && report.transfer.failure == nil &&
                    report.transfer.releaseVerified && report.processExitVerified {
                    statuses[index].state = .transferred
                    await observe(.statuses(statuses))
                    if Task.isCancelled { break }
                } else {
                    let releaseWarning = report.transfer.releaseVerified ? "" : " 设备连接释放未确认。"
                    let exitWarning = report.processExitVerified ? "" : " 辅助进程退出未确认，禁止继续发送。"
                    statuses[index].state = .stopped(report.message + releaseWarning + exitWarning)
                    await observe(.statuses(statuses))
                    break
                }
            } catch {
                statuses[index].state = .stopped(error.localizedDescription)
                await observe(.statuses(statuses))
                break
            }
        }
    }
}
