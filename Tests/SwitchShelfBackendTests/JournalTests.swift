import Foundation
import Testing
@testable import SwitchShelfBackend

@Suite("BackendJournal") struct BackendJournalTests {
    private func path() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("journal.json")
    }
    private let offers = [BackendFileOffer(id: "opaque", name: "game.nsp", byteCount: 10)]
    private func result(_ bytes: UInt64, _ phase: BackendFileTransferPhase, total: UInt64? = nil, exit: Bool = false) -> BackendTransferResult {
        .init(files: [.init(fileID: "opaque", byteCount: 10, uniqueBytesSent: bytes, phase: phase)],
              peerRequestedExit: exit, totalBytesSent: total ?? bytes)
    }

    @Test func roundTripAtomicReplacementAndRestart() async throws {
        let url = try path()
        let id = UUID()
        let journal = try await BackendTransferJournal.open(at: url)
        try await journal.begin(id: id, offers: offers)
        let first = try Data(contentsOf: url)
        try await journal.record(result(4, .partiallyTransferred), attemptID: id)
        let second = try Data(contentsOf: url)
        #expect(first != second)
        #expect((try JSONSerialization.jsonObject(with: second) as? [String: Any])?["schema"] as? Int == 1)
        let restarted = try await BackendTransferJournal.open(at: url)
        let attempt = try #require(await restarted.attempts().first)
        #expect(attempt.state == .interrupted)
        #expect(attempt.files.first?.uniqueBytesSent == 4)
        await #expect(throws: BackendJournalError.invalidTransition) {
            try await restarted.record(result(10, .transferredAwaitingConfirmation), attemptID: id)
        }
        #expect(try await BackendTransferJournal.open(at: url).attempts().first?.state == .interrupted)
    }

    @Test func finishedIsNotInstalledAndInvalidTransitions() async throws {
        let journal = try await BackendTransferJournal.open(at: path())
        let id = UUID()
        try await journal.begin(id: id, offers: offers)
        await #expect(throws: BackendJournalError.invalidTransition) { try await journal.begin(offers: offers) }
        await #expect(throws: BackendJournalError.invalidSnapshot) { try await journal.record(result(0, .partiallyTransferred), attemptID: id) }
        await #expect(throws: BackendJournalError.invalidSnapshot) { try await journal.record(result(11, .transferredAwaitingConfirmation), attemptID: id) }
        try await journal.record(result(10, .transferredAwaitingConfirmation), attemptID: id)
        await #expect(throws: BackendJournalError.invalidSnapshot) { try await journal.record(result(4, .partiallyTransferred), attemptID: id) }
        await #expect(throws: BackendJournalError.invalidTransition) { try await journal.end(attemptID: id, state: .finished) }
        try await journal.record(result(10, .transferredAwaitingConfirmation, exit: true), attemptID: id)
        try await journal.end(attemptID: id, state: .finished)
        #expect(await journal.attempts().first?.state == .finished)
        #expect(await journal.attempts().first?.files.first?.phase == .transferredAwaitingConfirmation)
        await #expect(throws: BackendJournalError.invalidTransition) { try await journal.end(attemptID: id, state: .failed) }
    }

    @Test func oldRetransmissionBudgetCannotFundNewUniqueBytes() async throws {
        let journal = try await BackendTransferJournal.open(at: path())
        let id = UUID()
        try await journal.begin(id: id, offers: offers)
        try await journal.record(result(2, .partiallyTransferred, total: 100), attemptID: id)
        await #expect(throws: BackendJournalError.invalidSnapshot) {
            try await journal.record(result(3, .partiallyTransferred, total: 100), attemptID: id)
        }
        #expect(await journal.attempts().first?.files.first?.uniqueBytesSent == 2)
        try await journal.record(result(3, .partiallyTransferred, total: 101), attemptID: id)
    }

    @Test func explicitEarlyExitKeepsPartialCoverage() async throws {
        let url = try path()
        let journal = try await BackendTransferJournal.open(at: url)
        let id = UUID()
        try await journal.begin(id: id, offers: offers)
        try await journal.record(result(2, .partiallyTransferred, exit: true), attemptID: id)
        try await journal.end(attemptID: id, state: .finished)
        let loaded = try await BackendTransferJournal.open(at: url)
        #expect(await loaded.attempts().first?.state == .finished)
        #expect(await loaded.attempts().first?.files.first?.phase == .partiallyTransferred)
    }

    @Test func postRenameFailureFencesOwnerAndPreservesDisk() async throws {
        enum Injected: Error { case failure }
        let url = try path()
        let journal = try await BackendTransferJournal.openForTesting(at: url, afterRename: { throw Injected.failure })
        let first = UUID()
        await #expect(throws: BackendJournalError.ioFailure) { try await journal.begin(id: first, offers: offers) }
        let disk = try Data(contentsOf: url)
        #expect(await journal.attempts().isEmpty)
        await #expect(throws: BackendJournalError.recoveryRequired) { try await journal.begin(offers: offers) }
        #expect(try Data(contentsOf: url) == disk)
        let recovered = try await BackendTransferJournal.open(at: url)
        #expect(await recovered.attempts().first?.id == first)
        #expect(await recovered.attempts().first?.state == .interrupted)
    }

    @Test func corruptAndUnknownSchemaArePreserved() async throws {
        let url = try path()
        for bytes in [Data("garbled".utf8), Data("{\"schema\":999,\"attempts\":[]}".utf8), Data(repeating: 3, count: 1_048_577)] {
            try bytes.write(to: url)
            await #expect(throws: BackendJournalError.recoveryRequired) { try await BackendTransferJournal.open(at: url) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test func corruptConsistencyAndSymlinkArePreserved() async throws {
        let url = try path()
        let invalid = Data("{\"schema\":1,\"attempts\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"state\":\"active\",\"files\":[{\"fileID\":\"a\",\"byteCount\":10,\"uniqueBytesSent\":11,\"phase\":\"partiallyTransferred\"}],\"totalBytesSent\":11,\"peerRequestedExit\":false,\"startedAt\":0,\"updatedAt\":0}]}".utf8)
        try invalid.write(to: url)
        await #expect(throws: BackendJournalError.recoveryRequired) { try await BackendTransferJournal.open(at: url) }
        #expect(try Data(contentsOf: url) == invalid)
        let link = url.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: BackendJournalError.recoveryRequired) { try await BackendTransferJournal.open(at: link) }
        #expect(try Data(contentsOf: url) == invalid)
        let fifo = url.deletingLastPathComponent().appendingPathComponent("pipe.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: BackendJournalError.recoveryRequired) { try await BackendTransferJournal.open(at: fifo) }
    }

    @Test func invalidPersistedAttemptStatesPreserved() async throws {
        let url = try path()
        let journal = try await BackendTransferJournal.open(at: url)
        try await journal.begin(id: UUID(), offers: offers)
        let original = try Data(contentsOf: url)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var attempts = try #require(object["attempts"] as? [[String: Any]])
        let active = attempts[0]
        var finished = active
        finished["state"] = "finished"
        attempts[0] = finished
        object["attempts"] = attempts
        let invalidFinish = try JSONSerialization.data(withJSONObject: object)
        try invalidFinish.write(to: url)
        await #expect(throws: BackendJournalError.recoveryRequired) { try await BackendTransferJournal.open(at: url) }
        #expect(try Data(contentsOf: url) == invalidFinish)
        var second = active
        second["id"] = UUID().uuidString
        object["attempts"] = [active, second]
        let invalidConcurrent = try JSONSerialization.data(withJSONObject: object)
        try invalidConcurrent.write(to: url)
        await #expect(throws: BackendJournalError.recoveryRequired) { try await BackendTransferJournal.open(at: url) }
        #expect(try Data(contentsOf: url) == invalidConcurrent)
    }

    @Test func restartDoesNotMoveTimestampBackward() async throws {
        let url = try path()
        let journal = try await BackendTransferJournal.open(at: url)
        try await journal.begin(offers: offers)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var attempts = try #require(object["attempts"] as? [[String: Any]])
        attempts[0]["updatedAt"] = 4_000_000_000.0
        object["attempts"] = attempts
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let restarted = try await BackendTransferJournal.open(at: url)
        #expect(await restarted.attempts().first?.state == .interrupted)
        #expect(await restarted.attempts().first?.updatedAt.timeIntervalSinceReferenceDate == 4_000_000_000)
    }

    @Test func concurrentProgressKeepsPartialState() async throws {
        let url = try path()
        let journal = try await BackendTransferJournal.open(at: url)
        let id = UUID()
        try await journal.begin(id: id, offers: offers)
        let update = result(5, .partiallyTransferred)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 { group.addTask { try await journal.record(update, attemptID: id) } }
            try await group.waitForAll()
        }
        try await journal.end(attemptID: id, state: .failed)
        let opened = try await BackendTransferJournal.open(at: url)
        #expect(await opened.attempts().first?.files.first?.uniqueBytesSent == 5)
        #expect(await opened.attempts().first?.state == .failed)
    }
}
