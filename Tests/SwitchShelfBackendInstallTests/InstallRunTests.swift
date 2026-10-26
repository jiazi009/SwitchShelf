import Foundation
import Testing
import SwitchShelfBackend
import SwitchShelfBackendInstall

private func le(_ value: UInt64, bytes: Int) -> Data {
    Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
}

private func header(type: UInt32, command: UInt32, size: UInt32 = 0) -> Data {
    Data("DBI0".utf8) + le(UInt64(type), bytes: 4) + le(UInt64(command), bytes: 4) + le(UInt64(size), bytes: 4)
}

private func rangePayload(size: UInt32, offset: UInt64, name: Data) -> Data {
    le(UInt64(size), bytes: 4) + le(offset, bytes: 8) + le(UInt64(name.count), bytes: 4) + name
}

private actor ScriptedTransport: BackendByteTransport {
    private var inbound: Data
    private var writeCount = 0
    private var written = Data()
    private var closes = 0
    private let failWriteAt: Int?
    private let fragmentSize: Int

    init(inbound: Data, failWriteAt: Int? = nil, fragmentSize: Int = 7) {
        self.inbound = inbound
        self.failWriteAt = failWriteAt
        self.fragmentSize = fragmentSize
    }

    func read(maximumLength: Int, timeoutMilliseconds: UInt32) throws -> Data {
        guard !inbound.isEmpty else { throw BackendError.timeout }
        let count = min(fragmentSize, maximumLength, inbound.count)
        let part = Data(inbound.prefix(count))
        inbound.removeFirst(count)
        return part
    }

    func write(_ data: Data, timeoutMilliseconds: UInt32) throws {
        writeCount += 1
        if let failWriteAt, writeCount == failWriteAt { throw BackendError.disconnected }
        written.append(data)
    }

    func close() { closes += 1 }

    func closeCount() -> Int { closes }
    func writeCountValue() -> Int { writeCount }
}

private actor ScriptedProvider: BackendInstallTransportProviding {
    private let transport: ScriptedTransport?
    private let failure: BackendError?
    private(set) var opens = 0

    init(transport: ScriptedTransport) {
        self.transport = transport
        self.failure = nil
    }

    init(failure: BackendError) {
        self.transport = nil
        self.failure = failure
    }

    func makeTransport() async throws -> any BackendByteTransport {
        opens += 1
        if let failure { throw failure }
        guard let transport else { throw BackendError.unavailable }
        return transport
    }

    func openCount() -> Int { opens }
}

@Suite("BackendInstall")
struct BackendInstallTests {
    private func temporaryDirectory() throws -> URL {
        // The allowlisted reader rejects symlink ancestors; /var is a symlink to
        // /private/var on macOS, so tests must start from the canonical path.
        guard let canonical = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw BackendError.unavailable
        }
        defer { free(canonical) }
        let url = URL(fileURLWithPath: String(cString: canonical))
            .appendingPathComponent("SwitchShelfInstallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSource(_ directory: URL, name: String = "小游戏.nsp", bytes: Int = 4) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x5a, count: bytes).write(to: url)
        return url
    }

    @Test func missingSourceFailsBeforeDeviceAccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = ScriptedTransport(inbound: Data())
        let provider = ScriptedProvider(transport: transport)
        let request = BackendInstallRequest(fileURL: directory.appendingPathComponent("不存在.nsp"),
                                            journalURL: directory.appendingPathComponent("journal.json"),
                                            sessionTimeoutSeconds: 30)
        let report = await BackendInstallRunner.run(request, provider: provider)
        #expect(report.outcome == .failed)
        #expect(report.exitCode == 1)
        #expect(await provider.openCount() == 0)
        #expect(await transport.closeCount() == 0)
    }

    @Test func successfulTransferRecordsFinishedHostEvidence() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let name = Data(source.lastPathComponent.utf8)
        var inbound = Data()
        inbound += header(type: 0, command: 3)
        inbound += header(type: 2, command: 3)
        let payload = rangePayload(size: 4, offset: 0, name: name)
        inbound += header(type: 0, command: 2, size: UInt32(payload.count)) + payload
        inbound += header(type: 2, command: 2)
        inbound += header(type: 0, command: 0)
        let transport = ScriptedTransport(inbound: inbound)
        let provider = ScriptedProvider(transport: transport)
        let journalURL = directory.appendingPathComponent("journal.json")
        let request = BackendInstallRequest(fileURL: source, journalURL: journalURL,
                                            sessionTimeoutSeconds: 30, maximumChunkSize: 2)
        let report = await BackendInstallRunner.run(request, provider: provider)
        #expect(report.outcome == .transferredAwaitingConfirmation)
        #expect(report.exitCode == 0)
        #expect(report.byteCount == 4)
        #expect(report.uniqueBytesSent == 4)
        #expect(report.peerRequestedExit)
        #expect(report.journalState == BackendAttemptState.finished.rawValue)
        #expect(await provider.openCount() == 1)
        #expect(await transport.closeCount() == 1)

        let reopened = try await BackendTransferJournal.open(at: journalURL)
        let attempts = await reopened.attempts()
        #expect(attempts.count == 1)
        #expect(attempts[0].state == .finished)
        #expect(attempts[0].peerRequestedExit)
        #expect(attempts[0].files.count == 1)
        #expect(attempts[0].files[0].uniqueBytesSent == 4)
        #expect(attempts[0].files[0].phase == .transferredAwaitingConfirmation)
    }

    @Test func busyLeaseMapsToDeviceBusy() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let provider = ScriptedProvider(failure: .busy)
        let journalURL = directory.appendingPathComponent("journal.json")
        let request = BackendInstallRequest(fileURL: source, journalURL: journalURL, sessionTimeoutSeconds: 30)
        let report = await BackendInstallRunner.run(request, provider: provider)
        #expect(report.outcome == .deviceBusy)
        #expect(report.exitCode == 4)
        #expect(await provider.openCount() == 1)
        let reopened = try await BackendTransferJournal.open(at: journalURL)
        let attempts = await reopened.attempts()
        #expect(attempts.count == 1)
        #expect(attempts[0].state == .failed)
        #expect(attempts[0].files[0].uniqueBytesSent == 0)
    }

    @Test func disconnectDuringHostDataWriteReportsIncompleteTransfer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let name = Data(source.lastPathComponent.utf8)
        var inbound = Data()
        inbound += header(type: 0, command: 3)
        inbound += header(type: 2, command: 3)
        let payload = rangePayload(size: 4, offset: 0, name: name)
        inbound += header(type: 0, command: 2, size: UInt32(payload.count)) + payload
        inbound += header(type: 2, command: 2)
        inbound += header(type: 0, command: 0)
        let transport = ScriptedTransport(inbound: inbound, failWriteAt: 5)
        let provider = ScriptedProvider(transport: transport)
        let journalURL = directory.appendingPathComponent("journal.json")
        let request = BackendInstallRequest(fileURL: source, journalURL: journalURL,
                                            sessionTimeoutSeconds: 30, maximumChunkSize: 2)
        let report = await BackendInstallRunner.run(request, provider: provider)
        #expect(report.outcome == .incompleteTransfer)
        #expect(report.exitCode == 2)
        #expect(!report.peerRequestedExit)
        #expect(await transport.closeCount() == 1)
        let reopened = try await BackendTransferJournal.open(at: journalURL)
        let attempts = await reopened.attempts()
        #expect(attempts.count == 1)
        #expect(attempts[0].state == .failed)
        #expect(!attempts[0].peerRequestedExit)
    }

    @Test func timeoutWhileWaitingForDeviceAckReportsIncompleteTransfer() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let name = Data(source.lastPathComponent.utf8)
        var inbound = Data()
        inbound += header(type: 0, command: 3)
        inbound += header(type: 2, command: 3)
        let payload = rangePayload(size: 4, offset: 0, name: name)
        inbound += header(type: 0, command: 2, size: UInt32(payload.count)) + payload
        let transport = ScriptedTransport(inbound: inbound)
        let provider = ScriptedProvider(transport: transport)
        let request = BackendInstallRequest(fileURL: source,
                                            journalURL: directory.appendingPathComponent("journal.json"),
                                            sessionTimeoutSeconds: 30, maximumChunkSize: 2)
        let report = await BackendInstallRunner.run(request, provider: provider)
        #expect(report.outcome == .incompleteTransfer)
        #expect(report.exitCode == 2)
        #expect(await transport.closeCount() == 1)
    }

    @Test func unwritableJournalFailsBeforeDeviceAccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSource(directory)
        let transport = ScriptedTransport(inbound: Data())
        let provider = ScriptedProvider(transport: transport)
        let request = BackendInstallRequest(fileURL: source,
                                            journalURL: URL(fileURLWithPath: "/dev/null/not-a-directory/journal.json"),
                                            sessionTimeoutSeconds: 30)
        let report = await BackendInstallRunner.run(request, provider: provider)
        #expect(report.outcome == .journalUnavailable)
        #expect(report.exitCode == 5)
        #expect(await provider.openCount() == 0)
        #expect(await transport.closeCount() == 0)
    }
}
