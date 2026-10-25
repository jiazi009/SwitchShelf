import CDBIBridge
import Foundation
import Testing
@testable import SwitchShelfDevice

private func numbers(_ values: [(UInt64, Int)]) -> Data {
    var result = Data()
    for (value, width) in values {
        for i in 0..<width { result.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
    }
    return result
}
private func ptpString(_ string: String) -> Data {
    var data = Data([UInt8(string.utf16.count + 1)])
    for unit in string.utf16 { data.append(numbers([(UInt64(unit), 2)])) }
    data.append(Data([0, 0])); return data
}
private func frame(type: UInt16 = 2, code: UInt16, tx: UInt32, body: Data = Data()) -> Data {
    numbers([(UInt64(body.count + 12), 4), (UInt64(type), 2), (UInt64(code), 2), (UInt64(tx), 4)]) + body
}
private func ack(_ tx: UInt32, parameters: [UInt32] = [], code: UInt16 = 0x2001) -> Data {
    frame(type: 3, code: code, tx: tx, body: numbers(parameters.map { (UInt64($0), 4) }))
}
private func deviceInfo(_ version: String = "Sphaira/fixture") -> Data {
    var data = numbers([(100, 2), (6, 4), (100, 2)]) + ptpString("microsoft.com: 1.0;") + numbers([(0, 2)])
    data.append(numbers([(2, 4), (0x9808, 2), (0x100d, 2)]))
    data.append(numbers(Array(repeating: (0, 4), count: 4)))
    for value in ["fixture", "fixture", version, "not-retained"] { data.append(ptpString(value)) }
    return data
}
private func sessionFrames(version: String = "Sphaira/fixture") -> [Data] {
    [frame(code: 0x1001, tx: 0, body: deviceInfo(version)) + ack(0), ack(0),
     frame(code: 0x1004, tx: 1, body: numbers([(2, 4), (9, 4), (8, 4)])) + ack(1),
     frame(code: 0x1005, tx: 2, body: Data(count: 26) + ptpString("Games") + ptpString("")) + ack(2),
     frame(code: 0x1005, tx: 3, body: Data(count: 26) + ptpString("Install") + ptpString("")) + ack(3)]
}
private actor USBFixture: SphairaUSBLink {
    let packetSize: Int
    var inputs: [Data]
    var writes: [Data] = []
    var closed = false
    init(inputs: [Data], packetSize: Int = 64) { self.inputs = inputs; self.packetSize = packetSize }
    func write(_ bytes: Data) { writes.append(bytes) }
    func read() throws -> Data {
        guard !inputs.isEmpty else { throw SphairaUploadError.invalidResponse }
        return inputs.removeFirst()
    }
    func close() { closed = true }
}
private actor NativeSourceFixture: SphairaUploadSource {
    let byteCount: UInt64
    var reads = 0
    init(_ size: Int) { byteCount = UInt64(size) }
    func validate() {}
    func read(offset: UInt64, count: Int) -> Data { reads += 1; return Data(repeating: 42, count: count) }
}

@Suite("Native sphaira MTP framing — fake USB only")
struct NativeSphairaMTPTests {
    @Test(arguments: [1, 51, 52, 53, 116, 500, 501, 1000, 1012, 1013], [64, 512, 1024])
    func packetBoundariesAndFinalZLP(_ size: Int, _ packet: Int) async throws {
        let link = USBFixture(inputs: sessionFrames() + [ack(4, parameters: [8, 0, 50]), ack(5)], packetSize: packet)
        let source = NativeSourceFixture(size)
        let transport = NativeSphairaMTP(link: link)
        let result = await SphairaMTPUpload(chunkSize: 7).upload(name: "a.nsp", from: source, through: transport)
        #expect(result.outcome == .transferredAwaitingConfirmation)
        #expect(result.bytesSubmitted == size)
        let writes = await link.writes
        let commandIndex = try #require(writes.firstIndex(where: {
            $0.count == 12 && NativeSphairaMTP.u16($0, 4) == 1 && NativeSphairaMTP.u16($0, 6) == 0x100d
        }))
        let fileWrites = Array(writes.dropFirst(commandIndex + 1))
        #expect(!fileWrites.isEmpty)
        #expect(fileWrites.dropLast().allSatisfy { !$0.isEmpty && $0.count.isMultiple(of: packet) })
        #expect(fileWrites.last?.count == (size + 12) % packet)
        let wire = fileWrites.reduce(Data(), +)
        #expect(wire == frame(code: 0x100d, tx: 5, body: Data(repeating: 42, count: size)))
        #expect(await link.closed)
    }

    @Test func fragmentedAndCoalescedMetadataContainers() async throws {
        let data = sessionFrames().reduce(Data(), +)
        let chunks = stride(from: 0, to: data.count, by: 3).map { Data(data[$0..<min($0 + 3, data.count)]) }
        let link = USBFixture(inputs: chunks)
        let transport = NativeSphairaMTP(link: link)
        let session = try await transport.inspectSession()
        #expect(session.lastTransaction == 3)
        #expect(try session.installStorage() == 8)
        try await transport.close()
    }

    @Test func rejectUnknownProviderBeforeAnyPackageReadOrCreate() async {
        let link = USBFixture(inputs: sessionFrames(version: "DBI/647"))
        let source = NativeSourceFixture(10)
        let result = await SphairaMTPUpload().upload(name: "a.nsp", from: source, through: NativeSphairaMTP(link: link))
        #expect(result.outcome == .notStarted)
        #expect(result.failure == .unsupportedSession)
        #expect(await source.reads == 0)
        #expect(await link.writes.allSatisfy { NativeSphairaMTP.u16($0, 6) != 0x9808 })
        #expect(await link.closed)
    }

    @Test func wrongMetadataTransactionAndOversizedContainerFailClosed() async {
        for input in [frame(code: 0x1001, tx: 99, body: deviceInfo()),
                      numbers([(65537, 4), (2, 2), (0x1001, 2), (0, 4)]), Data()] {
            let link = USBFixture(inputs: [input])
            let result = await SphairaMTPUpload().upload(name: "a.nsp", from: NativeSourceFixture(10),
                through: NativeSphairaMTP(link: link))
            #expect(result.outcome == .notStarted)
            #expect(await link.writes.count == 1)
            #expect(await link.closed)
        }
    }

    @Test func rejectionOfCreateDoesNotSendObjectOrRetry() async {
        let link = USBFixture(inputs: sessionFrames() + [ack(4, code: 0x2019)])
        let source = NativeSourceFixture(10)
        let result = await SphairaMTPUpload().upload(name: "a.nsp", from: source, through: NativeSphairaMTP(link: link))
        #expect(result.outcome == .deviceStateUnknown)
        #expect(result.detail?.contains("2019") == true)
        #expect(await source.reads == 0)
        #expect(await link.closed)
    }

    @Test func deviceDatasetBoundsAndUTF16() throws {
        #expect(try SphairaDeviceInfo.decode(deviceInfo("Sphaira/🎮")).version == "Sphaira/🎮")
        for data in [Data(), deviceInfo().dropLast(), deviceInfo() + Data([0]), Data(count: 65537)] {
            #expect(throws: SphairaUploadError.self) { try SphairaDeviceInfo.decode(Data(data)) }
        }
    }

    @Test func nativeBridgeRejectsInvalidArgumentsWithoutLoadingOrOpeningUSB() {
        #expect(ss_sphaira_usb_open(nil, nil, nil) == 8)
        #expect(ss_sphaira_usb_write(nil, nil, 0, nil) == 8)
        #expect(ss_sphaira_usb_read(nil, nil, 0, nil, nil) == 8)
        #expect(ss_sphaira_usb_close(nil) == 0)
    }

    @Test func noRawWriteWithoutInspectedStorageAndMatchingPhase() async {
        let link = USBFixture(inputs: [])
        let transport = NativeSphairaMTP(link: link)
        await #expect(throws: SphairaUploadError.self) {
            try await transport.sendCommand(SphairaUploadCodec.command(.sendObject, parameters: [], transaction: 1))
        }
        await #expect(throws: SphairaUploadError.self) { try await transport.writeData(Data([1])) }
        await #expect(throws: SphairaUploadError.self) { try await transport.endData() }
        #expect(await link.writes.isEmpty)
        try? await transport.close()
    }
}
