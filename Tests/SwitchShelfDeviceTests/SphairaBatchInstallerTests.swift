import Foundation
import Testing
@testable import SwitchShelfDevice

private actor BatchCapture {
    var sent: [String] = []
    var statuses: [SphairaBatchStatus] = []
    func sent(_ id: String) { sent.append(id) }
    func receive(_ event: SphairaBatchInstaller.Event) {
        if case .statuses(let value) = event { statuses = value }
    }
}
private actor BatchGate {
    var ready = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { ready = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("sphaira batch orchestration — simulated transport")
struct SphairaBatchInstallerTests {
    func fixture() throws -> (URL, [SphairaBatchItem]) {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let items = try (0..<3).map { index in
            let url = directory.appendingPathComponent("\(index).nsp")
            try Data([1]).write(to: url)
            let request = try SphairaInstallRequest.review(sourceURL: url, allowedRoot: directory, expectedBytes: 1, intendedTarget: "sd")
            return SphairaBatchItem(gameTitle: index < 2 ? "Game A" : "Game B", request: request)
        }
        return (directory, items)
    }
    func report(_ request: SphairaInstallRequest, outcome: SphairaUploadResult.Outcome = .transferredAwaitingConfirmation,
                failure: SphairaUploadResult.Failure? = nil, released: Bool = true, exited: Bool = true) -> SphairaInstallReport {
        .init(schemaVersion: 1, requestID: request.id,
              transfer: .init(outcome: outcome, bytesSubmitted: 1, failure: failure, releaseVerified: released),
              message: "fixture result", processExitVerified: exited)
    }
    @Test func successRunsAllItemsInOrder() async throws {
        let (directory, items) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let capture = BatchCapture()
        await SphairaBatchInstaller.run(items, send: { request, _ in
            #expect(request.userConfirmed)
            await capture.sent(request.id)
            return report(request)
        }, observe: { await capture.receive($0) })
        #expect(await capture.sent == items.map(\.id))
        let statuses = await capture.statuses
        #expect(statuses.allSatisfy { if case .transferred = $0.state { true } else { false } })
    }
    @Test(arguments: [0, 1, 2, 3, 4]) func errorsStopBeforeNextItem(_ mode: Int) async throws {
        let (directory, items) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let capture = BatchCapture()
        await SphairaBatchInstaller.run(items, send: { request, _ in
            await capture.sent(request.id)
            if mode == 0 { throw SphairaUploadError.sourceChanged }
            if mode == 1 { return report(request, outcome: .deviceStateUnknown, failure: .transport) }
            if mode == 2 { return report(request, released: false) }
            if mode == 3 { return report(request, exited: false) }
            return report(request, outcome: .notStarted, failure: .source)
        }, observe: { await capture.receive($0) })
        #expect(await capture.sent == [items[0].id])
        let statuses = await capture.statuses
        if case .stopped = statuses[0].state {} else { Issue.record("first item must stop") }
        if case .waiting = statuses[1].state {} else { Issue.record("next item must remain unsent") }
    }
    @Test func cancellationStopsBeforeNextItem() async throws {
        let (directory, items) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let capture = BatchCapture(), gate = BatchGate()
        let task = Task {
            await SphairaBatchInstaller.run(items, send: { request, _ in
                await capture.sent(request.id)
                await gate.wait()
                return report(request)
            }, observe: { await capture.receive($0) })
        }
        while !(await gate.ready) { await Task.yield() }
        task.cancel()
        await gate.release()
        await task.value
        #expect(await capture.sent == [items[0].id])
        let statuses = await capture.statuses
        if case .waiting = statuses[1].state {} else { Issue.record("cancel must leave next item unsent") }
    }
}
