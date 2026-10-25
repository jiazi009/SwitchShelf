import Darwin
import Foundation
import Testing
@testable import SwitchShelfDevice

private enum UploadFixtureError: Error { case failed }

/// Independent wire fixture, rather than using the production response codec.
private func responseBytes(transaction: UInt32, code: UInt16 = 0x2001, parameters: [UInt32] = []) -> Data {
    var bytes: [UInt8] = []
    func integer(_ value: UInt32, width: Int) {
        for i in 0..<width { bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
    integer(UInt32(12 + parameters.count * 4), width: 4)
    integer(3, width: 2); integer(UInt32(code), width: 2); integer(transaction, width: 4)
    for parameter in parameters { integer(parameter, width: 4) }
    return Data(bytes)
}

private func session(version: String = "Sphaira/fixture", operations: Set<UInt16> = [0x9808, 0x100d],
                     storages: [MTPStorage] = [.init(id: 0xfffffff9, name: "Games"), .init(id: 0xfffffff8, name: "Install")],
                     transaction: UInt32 = 20) -> SphairaUploadSession {
    .init(deviceVersion: version, supportedOperations: operations, storages: storages, lastTransaction: transaction)
}

private actor UploadTransportFixture: SphairaUploadTransport {
    let sessionInfo: SphairaUploadSession
    let failAt: String?
    let createResponse: Data?
    let finalResponse: Data?
    let failClose: Bool
    var events: [String] = []
    var commands: [Data] = []
    var headers: [Data] = []
    var fileChunks: [Data] = []
    var phase = 0
    var responses = 0
    var writes = 0
    init(sessionInfo: SphairaUploadSession = session(), failAt: String? = nil,
         createResponse: Data? = nil, finalResponse: Data? = nil, failClose: Bool = false) {
        self.sessionInfo = sessionInfo; self.failAt = failAt
        self.createResponse = createResponse; self.finalResponse = finalResponse; self.failClose = failClose
    }
    func event(_ name: String) throws {
        events.append(name)
        if name == failAt { throw UploadFixtureError.failed }
    }
    func inspectSession() throws -> SphairaUploadSession { try event("inspect"); return sessionInfo }
    func sendCommand(_ container: Data) throws {
        commands.append(container); try event("command\(commands.count)")
    }
    func beginData(_ header: Data) throws {
        phase += 1; headers.append(header); try event("header\(phase)")
    }
    func writeData(_ bytes: Data) throws {
        if phase == 2 { writes += 1; try event("file\(writes)"); fileChunks.append(bytes) }
        else { try event("metadata") }
    }
    func endData() throws { try event("end\(phase)") }
    func receiveResponse() throws -> Data {
        responses += 1; try event("response\(responses)")
        if responses == 1 {
            return createResponse ?? responseBytes(transaction: sessionInfo.lastTransaction + 1,
                parameters: [0xfffffff8, 0, 50])
        }
        return finalResponse ?? responseBytes(transaction: sessionInfo.lastTransaction + 2)
    }
    func close() throws { try event("close"); if failClose { throw UploadFixtureError.failed } }
}

private actor UploadSourceFixture: SphairaUploadSource {
    let byteCount: UInt64
    let failValidation: Int?
    let wrongReadSize: Int
    let cancelOnRead: Bool
    var validations = 0
    var reads: [(UInt64, Int)] = []
    init(byteCount: UInt64 = 13, failValidation: Int? = nil, wrongReadSize: Int = 0, cancelOnRead: Bool = false) {
        self.byteCount = byteCount; self.failValidation = failValidation
        self.wrongReadSize = wrongReadSize; self.cancelOnRead = cancelOnRead
    }
    func validate() throws {
        validations += 1
        if validations == failValidation { throw UploadFixtureError.failed }
    }
    func read(offset: UInt64, count: Int) -> Data {
        reads.append((offset, count))
        if cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
        return Data(repeating: UInt8(truncatingIfNeeded: offset), count: max(0, count + wrongReadSize))
    }
}

@Suite("sphaira MTP upload wire contract — no hardware")
struct SphairaUploadCodecTests {
    @Test func independentCommandAndPropertyVectors() throws {
        let command = try SphairaUploadCodec.command(.sendObjectPropList,
            parameters: [0xfffffff8, .max, 0x3000, 1, 7], transaction: 21)
        #expect(Array(command) == [32, 0, 0, 0, 1, 0, 8, 152, 21, 0, 0, 0,
            248, 255, 255, 255, 255, 255, 255, 255, 0, 48, 0, 0, 1, 0, 0, 0, 7, 0, 0, 0])
        let property = try SphairaUploadCodec.filenameProperty("a.nsp")
        #expect(Array(property) == [1, 0, 0, 0, 0, 0, 0, 0, 7, 220, 255, 255, 6,
            97, 0, 46, 0, 110, 0, 115, 0, 112, 0, 0, 0])
        #expect(try SphairaUploadCodec.filenameProperty("🎮.nsp")[12] == 7)
    }

    @Test func largePackagesKeep64BitLengthWithoutAllocatingPackageData() throws {
        let size: UInt64 = (1 << 32) + 7
        #expect(try SphairaUploadCodec.propertyParameters(storage: 8, byteCount: size) == [8, .max, 0x3000, 1, 7])
        let header = try SphairaUploadCodec.dataHeader(.sendObject, payloadBytes: size, transaction: 22)
        #expect(Array(header) == [255, 255, 255, 255, 2, 0, 13, 16, 22, 0, 0, 0])
        #expect(Array(try SphairaUploadCodec.dataHeader(.sendObject, payloadBytes: 13, transaction: 22).prefix(4)) == [25, 0, 0, 0])
    }

    @Test func malformedResponsesAreRejected() throws {
        let valid = responseBytes(transaction: 21, parameters: [8, 0, 50])
        #expect(try SphairaUploadCodec.response(valid, transaction: 21, parameters: 3) == [8, 0, 50])
        for data in [Data(), valid.dropLast(), valid + Data([0]), responseBytes(transaction: 20, parameters: [8, 0, 50]),
                     responseBytes(transaction: 21), responseBytes(transaction: 21, code: 0x2019)] {
            #expect(throws: SphairaUploadError.self) {
                try SphairaUploadCodec.response(Data(data), transaction: 21, parameters: 3)
            }
        }
        var badType = valid; badType[4] = 2
        var badLength = valid; badLength[0] = 12
        for data in [badType, badLength] {
            #expect(throws: SphairaUploadError.invalidResponse) {
                try SphairaUploadCodec.response(data, transaction: 21, parameters: 3)
            }
        }
    }

    @Test func invalidRequestsCannotEncode() {
        #expect(throws: SphairaUploadError.self) { try SphairaUploadCodec.filenameProperty("../file.nsp") }
        #expect(throws: SphairaUploadError.self) { try SphairaUploadCodec.command(.sendObject, parameters: [1], transaction: 1) }
        #expect(throws: SphairaUploadError.self) { try SphairaUploadCodec.command(.sendObject, parameters: [], transaction: 0) }
        #expect(throws: SphairaUploadError.self) { try SphairaUploadCodec.propertyParameters(storage: 0, byteCount: 1) }
        #expect(throws: SphairaUploadError.self) { try SphairaUploadCodec.propertyParameters(storage: 8, byteCount: 0) }
        #expect(throws: SphairaUploadError.self) { try SphairaUploadCodec.dataHeader(.sendObject, payloadBytes: .max, transaction: 1) }
        // Adding an upload codec must not broaden the existing inventory channel.
        for code: UInt16 in [0x9808, 0x100d, 0x100b, 0x100f] {
            #expect(throws: DeviceServiceError.self) { try PTPCodec.command(code, parameters: [], transaction: 1) }
        }
    }
}

@Suite("sphaira bounded upload state — fake transports only")
struct SphairaMTPUploadTests {
    @Test func sendsSequentialChunksAndWaitsForDeviceConfirmation() async throws {
        let source = UploadSourceFixture()
        let transport = UploadTransportFixture()
        let result = await SphairaMTPUpload(chunkSize: 4).upload(name: "fixture.nsp", from: source, through: transport)
        #expect(result == .init(outcome: .transferredAwaitingConfirmation, bytesSubmitted: 13, failure: nil, releaseVerified: true))
        #expect(await source.reads.map(\.0) == [0, 4, 8, 12])
        #expect(await transport.fileChunks.map(\.count) == [4, 4, 4, 1])
        #expect(await transport.events == ["inspect", "command1", "header1", "metadata", "end1", "response1",
            "command2", "header2", "file1", "file2", "file3", "file4", "end2", "response2", "close"])
        let commands = await transport.commands
        #expect(commands.count == 2)
        #expect(commands[0][8] == 21 && commands[1][8] == 22) // Continues the inspected session's transaction IDs.
    }

    @Test(arguments: ["inspect", "command1", "header1", "metadata", "end1", "response1", "command2", "header2", "file1", "file2", "end2", "response2"])
    func transportFailuresNeverRetryOrDelete(_ stage: String) async {
        let transport = UploadTransportFixture(failAt: stage)
        let result = await SphairaMTPUpload(chunkSize: 4).upload(name: "fixture.nsp", from: UploadSourceFixture(), through: transport)
        #expect(result.failure == .transport)
        #expect(result.outcome == (stage == "inspect" ? .notStarted : .deviceStateUnknown))
        #expect(result.releaseVerified)
        let events = await transport.events
        #expect(events.last == "close")
        #expect(events.filter { $0 == stage }.count == 1)
        #expect(await transport.commands.count <= 2)
        if stage == "file2" { #expect(result.bytesSubmitted == 4) }
    }

    @Test func localDescriptorSourceFeedsTheFakeWireWithoutChangingItsFile() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let canonical = try #require(realpath(temporary.path, nil))
        defer { free(canonical) }
        let root = URL(fileURLWithPath: String(cString: canonical))
        let file = root.appendingPathComponent("fixture.nsp")
        let original = Data(0..<13)
        try original.write(to: file)
        let source = try SphairaPackageSource(url: file, allowedRoot: root, expectedBytes: 13)
        let transport = UploadTransportFixture()
        let result = await SphairaMTPUpload(chunkSize: 4).upload(name: "fixture.nsp", from: source, through: transport)
        await source.close()
        #expect(result.outcome == .transferredAwaitingConfirmation)
        #expect(Data(await transport.fileChunks.flatMap { $0 }) == original)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func deviceBusyDoesNotRetryOrSendPackageBytes() async {
        let transport = UploadTransportFixture(createResponse: responseBytes(transaction: 21, code: 0x2019))
        let source = UploadSourceFixture()
        let result = await SphairaMTPUpload().upload(name: "fixture.nsp", from: source, through: transport)
        #expect(result.failure == .protocolViolation)
        #expect(result.outcome == .deviceStateUnknown)
        #expect(await source.reads.isEmpty)
        #expect(await transport.commands.count == 1)
    }

    @Test func unexpectedCreatedObjectLocationOrHandleStopsTransfer() async {
        for parameters: [UInt32] in [[8, 0, 50], [0xfffffff8, 99, 50], [0xfffffff8, 0, 0],
                                     [0xfffffff8, 0, .max], [0xfffffff8, 0, 0xfffffff8], [0xfffffff8, 0, 0xfffffff9]] {
            let transport = UploadTransportFixture(createResponse: responseBytes(transaction: 21, parameters: parameters))
            let result = await SphairaMTPUpload().upload(name: "fixture.nsp", from: UploadSourceFixture(), through: transport)
            #expect(result.outcome == .deviceStateUnknown)
            #expect(result.failure == .protocolViolation)
            #expect(await transport.commands.count == 1)
        }
    }

    @Test func strictStorageSelectionAndProviderCapabilities() async {
        let invalid: [SphairaUploadSession] = [
            session(version: "DBI/647"), session(version: "Sphaira/"), session(operations: [0x100d]),
            session(storages: [.init(id: 9, name: "Games"), .init(id: 8, name: "microSD card")]),
            session(storages: [.init(id: 9, name: "Games"), .init(id: 8, name: "Install games")]),
            session(storages: [.init(id: 9, name: "Games"), .init(id: 8, name: "Install"), .init(id: 7, name: "Install")]),
            session(storages: [.init(id: 8, name: "Games"), .init(id: 8, name: "Install")]),
            session(storages: [.init(id: 9, name: "Games"), .init(id: 0, name: "Install")]),
            session(storages: [.init(id: 8, name: "Install")])
        ]
        for info in invalid {
            let transport = UploadTransportFixture(sessionInfo: info)
            let result = await SphairaMTPUpload().upload(name: "fixture.nsp", from: UploadSourceFixture(), through: transport)
            #expect(result.outcome == .notStarted)
            #expect(result.failure == .unsupportedSession)
            #expect(await transport.commands.isEmpty)
        }
        let labeled = session(storages: [.init(id: 9, name: "Games"), .init(id: 8, name: " Install (NSP, XCI, NSZ, XCZ, MSP) ")])
        #expect((try? labeled.installStorage()) == 8)
    }

    @Test func invalidSizeNameChunkOrTransactionDoesNotWrite() async {
        for (name, size, chunk, transaction): (String, UInt64, Int, UInt32) in [
            ("../a.nsp", 3, 4, 20), ("a.nsp", 0, 4, 20), ("a.nsp", .max, 4, 20),
            ("a.nsp", 3, 0, 20), ("a.nsp", 3, 4 * 1024 * 1024 + 1, 20), ("a.nsp", 3, 4, .max)
        ] {
            let transport = UploadTransportFixture(sessionInfo: session(transaction: transaction))
            let result = await SphairaMTPUpload(chunkSize: chunk).upload(name: name,
                from: UploadSourceFixture(byteCount: size), through: transport)
            #expect(result.outcome == .notStarted)
            #expect(result.failure == .invalidRequest)
            #expect(await transport.commands.isEmpty)
        }
    }

    @Test func sourceChangedBeforeOrDuringTransferIsNotSuccess() async {
        for validation in [1, 2, 3, 4, 10] {
            let transport = UploadTransportFixture()
            let source = UploadSourceFixture(failValidation: validation)
            let result = await SphairaMTPUpload(chunkSize: 4).upload(name: "fixture.nsp", from: source, through: transport)
            #expect(result.outcome == (validation == 1 ? .notStarted : .deviceStateUnknown))
            #expect(result.failure == .source)
            #expect(result.releaseVerified)
            #expect(await transport.responses <= 1)
        }
    }

    @Test(arguments: [-1, 1]) func wrongSourceReadLengthStopsBeforeSubmitting(_ adjustment: Int) async {
        let transport = UploadTransportFixture()
        let result = await SphairaMTPUpload(chunkSize: 4).upload(name: "fixture.nsp",
            from: UploadSourceFixture(wrongReadSize: adjustment), through: transport)
        #expect(result.outcome == .deviceStateUnknown)
        #expect(result.failure == .source)
        #expect(result.bytesSubmitted == 0)
        #expect(await transport.fileChunks.isEmpty)
    }

    @Test func cancellationBeforeAndAfterFirstDeviceCommandStillCloses() async {
        for cancelOnRead in [false, true] {
            let transport = UploadTransportFixture()
            let result = await Task {
                if !cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
                return await SphairaMTPUpload(chunkSize: 4).upload(name: "fixture.nsp",
                    from: UploadSourceFixture(cancelOnRead: cancelOnRead), through: transport)
            }.value
            #expect(result.outcome == (cancelOnRead ? .deviceStateUnknown : .notStarted))
            #expect(result.failure == .cancelled)
            #expect(result.bytesSubmitted == 0)
            #expect(result.releaseVerified)
            #expect(await transport.events.last == "close")
        }
    }

    @Test func missingFinalAckIsUnknownEvenAfterEveryByteWasSubmitted() async {
        let transport = UploadTransportFixture(finalResponse: responseBytes(transaction: 999))
        let result = await SphairaMTPUpload(chunkSize: 4).upload(name: "fixture.nsp", from: UploadSourceFixture(), through: transport)
        #expect(result.bytesSubmitted == 13)
        #expect(result.outcome == .deviceStateUnknown)
        #expect(result.failure == .protocolViolation)
    }

    @Test func closeFailureIsExplicitAndUploaderIsSingleUse() async {
        let transport = UploadTransportFixture(failClose: true)
        let uploader = SphairaMTPUpload(chunkSize: 4)
        let result = await uploader.upload(name: "fixture.nsp", from: UploadSourceFixture(), through: transport)
        #expect(result.outcome == .transferredAwaitingConfirmation)
        #expect(!result.releaseVerified)
        let again = await uploader.upload(name: "fixture.nsp", from: UploadSourceFixture(), through: transport)
        #expect(again.failure == .alreadyUsed)
        #expect(await transport.commands.count == 2)
        #expect(await transport.events.filter { $0 == "close" }.count == 1)
    }
}
