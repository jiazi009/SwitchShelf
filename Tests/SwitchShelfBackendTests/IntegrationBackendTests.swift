import Foundation
import Testing
import SwitchShelfBackend

/// Deterministic DBI fake; never constructs a native USB transport.
private actor IntegrationPeer: BackendByteTransport {
    private var input: Data
    private(set) var writes: [Data] = []
    private(set) var closes = 0

    init(input: Data) { self.input = input }
    func read(maximumLength: Int, timeoutMilliseconds: UInt32) throws -> Data {
        guard !input.isEmpty else { throw BackendError.timeout }
        let length = min(2, maximumLength, input.count)
        let bytes = Data(input.prefix(length))
        input.removeFirst(length)
        return bytes
    }
    func write(_ data: Data, timeoutMilliseconds: UInt32) { writes.append(data) }
    func close() { closes += 1 }
    func evidence() -> ([Data], Int) { (writes, closes) }
}

@Suite("BackendIntegration") struct BackendIntegrationTests {
    private func le(_ value: UInt64, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func header(type: UInt32, command: UInt32, size: UInt32 = 0) -> Data {
        Data("DBI0".utf8) + le(UInt64(type), bytes: 4) +
            le(UInt64(command), bytes: 4) + le(UInt64(size), bytes: 4)
    }

    @Test func finishedRequiresExplicitFinalExitRecord() async throws {
        let temporary = FileManager.default.temporaryDirectory
        guard let canonical = realpath(temporary.path, nil) else { throw BackendError.unavailable }
        defer { free(canonical) }
        let folder = URL(fileURLWithPath: String(cString: canonical))
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tiny.nsp")
        try Data([0x61, 0x62]).write(to: url)
        let entry = BackendPreflightEntry(id: "opaque-full", name: "tiny.nsp", expectedBytes: 2,
                                          included: true, sourceURL: url, sourceAvailable: true, snapshotBytes: 2)
        let prepared = BackendPreflight.check(.init(items: [
            .init(id: "game", intendedTarget: "nand", entries: [entry])
        ]))
        #expect(prepared.isPrepared)
        let reader = try await AllowlistedBackendFileReader.open(bindings: [
            .init(id: "opaque-full", url: url, expectedBytes: 2)
        ])
        let journalURL = folder.appendingPathComponent("journal.json")
        let journal = try await BackendTransferJournal.open(at: journalURL)
        let attemptID = UUID()
        try await journal.begin(id: attemptID, offers: prepared.offers)
        let name = Data("tiny.nsp".utf8)
        let payload = le(2, bytes: 4) + le(0, bytes: 8) + le(UInt64(name.count), bytes: 4) + name
        let peer = IntegrationPeer(input: header(type: 0, command: 2, size: UInt32(payload.count)) +
                                   payload + header(type: 2, command: 2) + header(type: 0, command: 0))
        let session = BackendSession(transport: peer, reader: reader)
        let final = try await session.run(offers: prepared.offers, onProgress: { snapshot in
            try await journal.record(snapshot, attemptID: attemptID)
        })
        let beforeFinal = await journal.attempts()
        #expect(beforeFinal[0].state == .active && !beforeFinal[0].peerRequestedExit)
        #expect(beforeFinal[0].files[0].phase == .transferredAwaitingConfirmation)
        await #expect(throws: BackendJournalError.invalidTransition) {
            try await journal.end(attemptID: attemptID, state: .finished)
        }
        // EXIT is not included in a per-chunk callback; caller explicitly records
        // the final result before marking a host attempt finished.
        try await journal.record(final, attemptID: attemptID)
        try await journal.end(attemptID: attemptID, state: .finished)
        let reopened = try await BackendTransferJournal.open(at: journalURL)
        let attempts = await reopened.attempts()
        #expect(attempts[0].state == .finished && attempts[0].peerRequestedExit)
        #expect(attempts[0].files[0].phase == .transferredAwaitingConfirmation)
        #expect(attempts[0].files[0].uniqueBytesSent == 2)
        #expect(await peer.evidence().1 == 1)
    }

    @Test func preflightSourceProtocolAndJournalInterruption() async throws {
        let temporary = FileManager.default.temporaryDirectory
        guard let canonical = realpath(temporary.path, nil) else { throw BackendError.unavailable }
        defer { free(canonical) }
        let folder = URL(fileURLWithPath: String(cString: canonical))
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("游戏.nsp")
        try Data([0x41, 0x42, 0x43, 0x44]).write(to: url)
        let opaqueID = "content:opaque:ABC"
        let entry = BackendPreflightEntry(id: opaqueID, name: url.lastPathComponent,
                                          expectedBytes: 4, included: true, sourceURL: url,
                                          sourceAvailable: true, snapshotBytes: 4)
        let plan = BackendPreflightInput(items: [.init(id: "plan", intendedTarget: "sd", entries: [entry])])
        let prepared = BackendPreflight.check(plan)
        #expect(prepared.isPrepared && prepared.isCurrent(for: plan))
        #expect(prepared.offers == [.init(id: opaqueID, name: "游戏.nsp", byteCount: 4)])

        let reader = try await AllowlistedBackendFileReader.open(bindings: [
            BackendSourceBinding(id: opaqueID, url: url, expectedBytes: 4)
        ])
        await #expect(throws: BackendError.unknownFile) {
            try await reader.read(fileID: "different", offset: 0, length: 1)
        }
        let journalURL = folder.appendingPathComponent("attempt.json")
        let journal = try await BackendTransferJournal.open(at: journalURL)
        let attempt = UUID()
        try await journal.begin(id: attempt, offers: prepared.offers)

        let name = Data("游戏.nsp".utf8)
        let payload = le(2, bytes: 4) + le(1, bytes: 8) + le(UInt64(name.count), bytes: 4) + name
        let peer = IntegrationPeer(input:
            header(type: 0, command: 3) + header(type: 2, command: 3) +
            header(type: 0, command: 2, size: UInt32(payload.count)) + payload +
            header(type: 2, command: 2) + Data(repeating: 0, count: 16))
        let session = BackendSession(transport: peer, reader: reader,
                                     options: .init(maximumChunkSize: 2))
        await #expect(throws: BackendError.protocolViolation) {
            try await session.run(offers: prepared.offers, onProgress: { snapshot in
                try await journal.record(snapshot, attemptID: attempt)
            })
        }
        let (writes, closes) = await peer.evidence()
        #expect(closes == 1)
        #expect(writes.contains(Data([0x42, 0x43])))
        #expect(!writes.contains(Data([0x41, 0x42, 0x43, 0x44])))
        let active = await journal.attempts()
        #expect(active.count == 1)
        #expect(active[0].state == .active && !active[0].peerRequestedExit)
        #expect(active[0].files[0].phase == .partiallyTransferred)
        #expect(active[0].files[0].uniqueBytesSent == 2 && active[0].totalBytesSent == 2)

        // Reopening after interruption never infers EXIT, installation or auto-resume.
        let reopened = try await BackendTransferJournal.open(at: journalURL)
        let recovered = await reopened.attempts()
        #expect(recovered.count == 1)
        #expect(recovered[0].state == .interrupted && !recovered[0].peerRequestedExit)
        #expect(recovered[0].files[0].uniqueBytesSent == 2)
        #expect(recovered[0].files[0].phase == .partiallyTransferred)
    }
}
