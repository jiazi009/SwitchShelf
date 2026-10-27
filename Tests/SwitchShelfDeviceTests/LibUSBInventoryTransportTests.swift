import Foundation
import Testing
@testable import SwitchShelfDevice

private func bytes(_ values: [(UInt64, Int)]) -> Data {
    var data = Data()
    for (value, width) in values { for i in 0..<width { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) } }
    return data
}
private func container(_ type: UInt16, _ code: UInt16, _ tx: UInt32, _ payload: Data = Data()) -> Data {
    bytes([(UInt64(12 + payload.count), 4), (UInt64(type), 2), (UInt64(code), 2), (UInt64(tx), 4)]) + payload
}
private func string(_ value: String) -> Data {
    Data([UInt8(value.utf16.count + 1)]) + bytes(value.utf16.map { (UInt64($0), 2) }) + Data([0, 0])
}
private func dataResponse(_ code: UInt16, _ tx: UInt32, _ payload: Data) -> Data {
    container(2, code, tx, payload) + container(3, 0x2001, tx)
}
private actor InventoryUSBFixture: SphairaUSBLink {
    let packetSize = 512
    var incoming: [Data]
    var writes: [Data] = []
    var closed = false
    var closeFails = false
    init(_ incoming: [Data], closeFails: Bool = false) { self.incoming = incoming; self.closeFails = closeFails }
    func write(_ data: Data) { writes.append(data) }
    func read() throws -> Data {
        guard !incoming.isEmpty else { throw SphairaUploadError.invalidResponse }
        return incoming.removeFirst()
    }
    func close() throws { closed = true; if closeFails { throw SphairaUploadError.invalidResponse } }
}

@Suite("libusb inventory — fake USB only")
struct LibUSBInventoryTransportTests {
    @Test func metadataOnlyTransactionsAndClose() async throws {
        let storage = Data(count: 26) + string("Games") + Data([0])
        let wire = container(3, 0x2001, 0)
            + dataResponse(0x1004, 1, bytes([(1,4), (9,4)]))
            + dataResponse(0x1005, 2, storage)
            + dataResponse(0x1007, 3, bytes([(1,4), (41,4)]))
            + dataResponse(0x1008, 4, bytes([(9,4), (0x3001,2)]) + Data(count: 32) + bytes([(0,4)]) + Data(count: 10) + string("Game") + Data([0,0,0]))
            + container(3, 0x2001, 5)
        let chunks = stride(from: 0, to: wire.count, by: 7).map { Data(wire[$0..<min($0 + 7, wire.count)]) }
        let link = InventoryUSBFixture(chunks)
        let transport = try await LibUSBInventoryTransport.connect(link: link)
        #expect(try await transport.storages() == [MTPStorage(id: 9, name: "Games")])
        #expect(try await transport.children(storage: 9, parent: .max) == [41])
        #expect(try await transport.object(id: 41).isFolder)
        try await transport.close()
        let commands = await link.writes
        #expect(commands.map { NativeSphairaMTP.u16($0, 6) } == [0x1002, 0x1004, 0x1005, 0x1007, 0x1008, 0x1003])
        #expect(commands.map { NativeSphairaMTP.u32($0, 8) } == [0, 1, 2, 3, 4, 5])
        #expect(await link.closed)
    }
    @Test func badOpenClosesLinkAndNeverSendsMetadata() async {
        let link = InventoryUSBFixture([container(3, 0x2001, 99)])
        await #expect(throws: (any Error).self) { try await LibUSBInventoryTransport.connect(link: link) }
        #expect(await link.closed)
        #expect(await link.writes.count == 1)
    }
    @Test func malformedOrWrongTransactionPoisonsSession() async throws {
        for invalid in [container(2, 0x1004, 99, bytes([(0,4)])), bytes([(400_017,4), (2,2), (0x1004,2), (1,4)])] {
            let link = InventoryUSBFixture([container(3, 0x2001, 0), invalid])
            let transport = try await LibUSBInventoryTransport.connect(link: link)
            await #expect(throws: (any Error).self) { try await transport.storages() }
            await #expect(throws: (any Error).self) { try await transport.storages() }
            try await transport.close()
            #expect(await link.writes.count == 2)
            #expect(await link.closed)
        }
    }
    @Test func maximumHandleArraySpansMultipleUSBReads() async throws {
        let handles = bytes([(100_000, 4)]) + Data(count: 400_000)
        let wire = container(3, 0x2001, 0) + dataResponse(0x1007, 1, handles)
            + container(3, 0x2001, 2)
        let chunks = stride(from: 0, to: wire.count, by: 65_536).map {
            Data(wire[$0..<min($0 + 65_536, wire.count)])
        }
        let link = InventoryUSBFixture(chunks)
        let transport = try await LibUSBInventoryTransport.connect(link: link)
        #expect(try await transport.children(storage: 9, parent: .max).count == 100_000)
        try await transport.close()
        #expect(await link.closed)
    }
    @Test func invalidDatasetStopsFurtherMetadataCommands() async throws {
        let link = InventoryUSBFixture([container(3, 0x2001, 0),
                                        dataResponse(0x1004, 1, bytes([(1, 4)]))])
        let transport = try await LibUSBInventoryTransport.connect(link: link)
        await #expect(throws: (any Error).self) { try await transport.storages() }
        await #expect(throws: (any Error).self) { try await transport.children(storage: 9, parent: .max) }
        try await transport.close()
        #expect(await link.writes.count == 2)
        #expect(await link.closed)
    }
    @Test func oversizedObjectRejectedFromHeaderWithoutReadingPayload() async throws {
        let header = bytes([(4109, 4), (2, 2), (0x1008, 2), (1, 4)])
        let link = InventoryUSBFixture([container(3, 0x2001, 0), header, Data([0xff])])
        let transport = try await LibUSBInventoryTransport.connect(link: link)
        await #expect(throws: (any Error).self) { try await transport.object(id: 41) }
        try await transport.close()
        #expect(await link.incoming == [Data([0xff])])
        #expect(await link.writes.count == 2)
        #expect(await link.closed)
    }
    @Test func invalidResponsePhasesStopSession() async throws {
        let invalidPhases = [
            container(3, 0x2001, 1), // Success without the requested dataset.
            container(2, 0x1005, 1, bytes([(0, 4)])), // Wrong operation.
            container(4, 0x1004, 1), // Event in place of a data phase.
            container(2, 0x1004, 1, bytes([(0, 4)])) + container(3, 0x2001, 99),
            Data(), // Premature end of USB input.
        ]
        for invalid in invalidPhases {
            let link = InventoryUSBFixture([container(3, 0x2001, 0), invalid])
            let transport = try await LibUSBInventoryTransport.connect(link: link)
            await #expect(throws: (any Error).self) { try await transport.storages() }
            await #expect(throws: (any Error).self) { try await transport.storages() }
            try await transport.close()
            #expect(await link.writes.count == 2)
            #expect(await link.closed)
        }
    }
    @Test func deniedMetadataRequestKeepsNativeCodeAndReleasesUSB() async throws {
        let link = InventoryUSBFixture([container(3, 0x2001, 0), container(3, 0x2019, 1)])
        let transport = try await LibUSBInventoryTransport.connect(link: link)
        do {
            _ = try await transport.storages()
            Issue.record("Busy response must not produce an inventory")
        } catch let error as DeviceServiceError {
            #expect(error.code == .accessDeniedOrBusy)
            #expect(error.nativeCode == 0x2019)
        }
        try await transport.close()
        #expect(await link.writes.count == 2)
        #expect(await link.closed)
    }
    @Test func cancelledOpenReleasesUSBWithoutCommands() async {
        let link = InventoryUSBFixture([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LibUSBInventoryTransport.connect(link: link)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await link.writes.isEmpty)
        #expect(await link.closed)
    }
    @Test func failedCloseIsReported() async throws {
        let link = InventoryUSBFixture([container(3, 0x2001, 0), container(3, 0x2001, 1)], closeFails: true)
        let transport = try await LibUSBInventoryTransport.connect(link: link)
        await #expect(throws: (any Error).self) { try await transport.close() }
        #expect(await link.closed)
    }
    @Test func rejectedCloseStillReleasesUSB() async throws {
        let link = InventoryUSBFixture([container(3, 0x2001, 0), container(3, 0x2002, 1)])
        let transport = try await LibUSBInventoryTransport.connect(link: link)
        await #expect(throws: (any Error).self) { try await transport.close() }
        #expect(await link.closed)
    }
}
