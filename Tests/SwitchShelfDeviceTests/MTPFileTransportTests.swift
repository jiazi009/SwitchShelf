import Foundation
import Testing
@testable import SwitchShelfDevice

private func wire(_ type: UInt16, _ code: UInt16, _ transaction: UInt32, _ bytes: Data = Data()) -> Data {
    MTPFileDataset.header(length: UInt32(bytes.count + 12), type: type, code: code, transaction: transaction) + bytes
}
private func response(_ transaction: UInt32, _ parameters: [UInt32] = [], code: UInt16 = 0x2001) -> Data {
    var data = Data()
    for value in parameters { PTPCodec.append(value, to: &data) }
    return wire(3, code, transaction, data)
}
private actor FileUSBFixture: SphairaUSBLink {
    let packetSize: Int
    var incoming: [Data]
    var writes: [Data] = []
    var closed = false
    var closeFails: Bool
    init(_ incoming: [Data], packetSize: Int = 512, closeFails: Bool = false) {
        self.incoming = incoming; self.packetSize = packetSize; self.closeFails = closeFails
    }
    func write(_ data: Data) { writes.append(data) }
    func read() throws -> Data {
        guard !incoming.isEmpty else { throw MTPFileError.incompleteTransfer }
        return incoming.removeFirst()
    }
    func close() throws { closed = true; if closeFails { throw MTPFileError.invalidResponse } }
}
private actor DownloadObservation {
    var data = Data()
    var maximumChunk = 0
    func append(_ value: Data) { data.append(value); maximumChunk = max(maximumChunk, value.count) }
}

@Suite("MTP file transport — packet fixtures, no USB")
struct MTPFileTransportTests {
    @Test func storageMetadataKeepsCapacityAndWritableSDRole() throws {
        for name in ["microSD card", "Games", "Install"] {
            var data = Data()
            for value: UInt16 in [3, 2, 0] { PTPCodec.append(value, to: &data) }
            PTPCodec.append(UInt64(1_000), to: &data); PTPCodec.append(UInt64(400), to: &data)
            PTPCodec.append(UInt32(20), to: &data)
            data.append(try MTPFileDataset.string(name)); data.append(Data([0]))
            let value = try MTPFileDataset.storage(data, handle: 9).value
            #expect(value.capacityBytes == 1_000 && value.freeBytes == 400)
            #expect(value.canUpload == (name == "microSD card"))
        }
    }
    @Test func objectInfoDatasetRoundTripsAndLargeSentinelRemainsUnknown() throws {
        var data = try MTPFileDataset.objectInfo(storage: 9, parent: 22, name: "notes.txt", byteCount: 42)
        let value = try MTPFileDataset.object(data, handle: 55)
        #expect(value.storage == 9 && value.parent == 22 && value.name == "notes.txt" && value.byteCount == 42)
        data.replaceSubrange(8..<12, with: [255, 255, 255, 255])
        #expect(try MTPFileDataset.object(data, handle: 55).byteCount == nil)
        #expect(throws: MTPFileError.self) { try MTPFileDataset.objectInfo(storage: 9, parent: 22, name: "large", byteCount: UInt64(UInt32.max)) }
    }
    @Test func downloadStreamsAlignedPayloadAndSkipsItsTerminatingZLP() async throws {
        let bytes = Data(repeating: 0xab, count: 500) // Header + payload = 512 bytes.
        let link = FileUSBFixture([response(0), wire(2, 0x1009, 1, bytes), Data(), response(1), response(2)])
        let transport = MTPFileUSBTransport(link: link)
        let observation = DownloadObservation()
        try await transport.open()
        #expect(try await transport.download(55, expectedBytes: 500) { await observation.append($0) } == 500)
        try await transport.close()
        #expect(await observation.data == bytes)
        #expect(await link.closed)
        #expect(await link.writes.map { NativeSphairaMTP.u16($0, 6) } == [0x1002, 0x1009, 0x1003])
    }
    @Test func downloadLargerThanAReadIsBoundedAndExact() async throws {
        let bytes = Data(repeating: 0xcd, count: 1_100_000)
        let all = wire(2, 0x1009, 1, bytes) + response(1)
        let chunks = stride(from: 0, to: all.count, by: 65_536).map { Data(all[$0..<min($0 + 65_536, all.count)]) }
        let link = FileUSBFixture([response(0)] + chunks + [response(2)])
        let transport = MTPFileUSBTransport(link: link)
        let observation = DownloadObservation()
        try await transport.open()
        #expect(try await transport.download(55, expectedBytes: UInt64(bytes.count)) { await observation.append($0) } == UInt64(bytes.count))
        try await transport.close()
        #expect(await observation.data == bytes)
        #expect(await observation.maximumChunk <= 65_536)
    }
    @Test func uploadPacketBoundariesZeroLengthAndNoMutationOtherThanCreateAndSend() async throws {
        for packet in [64, 512, 1024] {
            for count in [0, 1, packet - 13, packet - 12, packet - 11, 1_048_583] {
                let bytes = Data(repeating: 0xab, count: count)
                let link = FileUSBFixture([response(0), response(1, [9, 22, 55]), response(2), response(3)], packetSize: packet)
                let transport = MTPFileUSBTransport(link: link)
                try await transport.open()
                #expect(try await transport.upload(storage: 9, parent: 22, name: "example.txt", byteCount: UInt64(count),
                    source: { offset, amount in Data(bytes[Int(offset)..<(Int(offset) + amount)]) }, progress: { _ in }) == UInt64(count))
                try await transport.close()
                let writes = await link.writes
                let commands = writes.enumerated().filter { _, data in data.count >= 12 && NativeSphairaMTP.u16(data, 4) == 1 }
                #expect(commands.map { NativeSphairaMTP.u16($0.element, 6) } == [0x1002, 0x100c, 0x100d, 0x1003])
                let start = try #require(commands.first(where: { NativeSphairaMTP.u16($0.element, 6) == 0x100d })?.offset)
                let end = try #require(commands.last?.offset)
                let phase = Array(writes[(start + 1)..<end])
                #expect(!phase.isEmpty)
                #expect(phase.dropLast().allSatisfy { $0.count.isMultiple(of: packet) && $0.count <= 1_048_576 })
                #expect(phase.reduce(into: Data()) { $0.append($1) } == wire(2, 0x100d, 2, bytes))
                #expect(phase.last?.isEmpty == ((count + 12).isMultiple(of: packet)))
                #expect(await link.closed)
            }
        }
    }
    @Test func malformedDownloadPoisonsSessionWithoutCloseSessionInjection() async throws {
        let link = FileUSBFixture([response(0), wire(2, 0x1009, 99, Data([1]))])
        let transport = MTPFileUSBTransport(link: link)
        try await transport.open()
        await #expect(throws: MTPFileError.self) { try await transport.download(55, expectedBytes: 1) { _ in } }
        try await transport.close()
        #expect(await link.closed)
        #expect(await link.writes.map { NativeSphairaMTP.u16($0, 6) } == [0x1002, 0x1009])
    }
    @Test func validBusyCreateResponseAllowsHealthySessionClose() async throws {
        let link = FileUSBFixture([response(0), response(1, code: 0x2019), response(2)])
        let transport = MTPFileUSBTransport(link: link)
        try await transport.open()
        do {
            _ = try await transport.upload(storage: 9, parent: 22, name: "empty.txt", byteCount: 0,
                                           source: { _, _ in Data() }, progress: { _ in })
            Issue.record("Device Busy must stop creation")
        } catch MTPFileError.response(0x2019) {}
        try await transport.close()
        let commands = await link.writes.filter { $0.count >= 12 && NativeSphairaMTP.u16($0, 4) == 1 }
        #expect(commands.map { NativeSphairaMTP.u16($0, 6) } == [0x1002, 0x100c, 0x1003])
    }
    @Test func malformedOrWrongTransactionResponseIsRejected() async throws {
        let link = FileUSBFixture([response(0), response(99)])
        let transport = MTPFileUSBTransport(link: link)
        try await transport.open()
        await #expect(throws: MTPFileError.self) { try await transport.download(55, expectedBytes: 0) { _ in } }
        try await transport.close()
        #expect(await link.writes.count == 2)
    }
    @Test func hostReleaseFailureIsReported() async throws {
        let link = FileUSBFixture([response(0), response(1)], closeFails: true)
        let transport = MTPFileUSBTransport(link: link)
        try await transport.open()
        await #expect(throws: MTPFileError.self) { try await transport.close() }
        #expect(await link.closed)
    }
}
