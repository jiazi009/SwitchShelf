import Foundation
import XCTest
@testable import SwitchShelfBackend

private actor Peer: BackendByteTransport {
    var input: Data
    var output: [Data] = []
    var closes = 0
    var failClose = false
    var empty = false
    var pause = false
    init(_ input: Data) { self.input = input }
    func read(maximumLength: Int, timeoutMilliseconds: UInt32) async throws -> Data {
        if pause { try await Task.sleep(for: .seconds(2)) }
        if empty { return Data() }
        guard !input.isEmpty else { throw BackendError.timeout }
        let count = min(input.count, maximumLength, 3)
        let result = Data(input.prefix(count))
        input.removeFirst(count)
        return result
    }
    func write(_ data: Data, timeoutMilliseconds: UInt32) async throws { output.append(data) }
    func close() async throws {
        closes += 1
        if failClose { throw BackendError.transport }
    }
    func snapshot() -> ([Data], Int) { (output, closes) }
    func setFailure() { failClose = true }
    func setEmpty() { empty = true }
    func setPause() { pause = true }
}

private actor Source: BackendFileReading {
    var short = false
    func read(fileID: String, offset: UInt64, length: Int) async throws -> Data {
        Data(repeating: 0x42, count: short ? max(0, length - 1) : length)
    }
    func setShort() { short = true }
}

private actor ProgressLog {
    var snapshots: [BackendTransferResult] = []
    var fail = false
    func record(_ result: BackendTransferResult) throws {
        snapshots.append(result)
        if fail { throw BackendError.sourceChanged }
    }
    func values() -> [BackendTransferResult] { snapshots }
    func setFailure() { fail = true }
}

final class BackendProtocolSessionTests: XCTestCase {
    private let offer = BackendFileOffer(id: "file", name: "游戏.nsp", byteCount: 10)
    private func header(_ type: BackendCodec.MessageType = .request, _ command: BackendCodec.Command,
                        _ size: UInt32 = 0) -> Data {
        BackendCodec.Header(type: type, command: command, payloadSize: size).encoded()
    }
    private func little(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func range(_ name: Data, _ offset: UInt64, _ size: UInt32) -> Data {
        var payload = little(UInt64(size), count: 4)
        payload += little(offset, count: 8)
        payload += little(UInt64(name.count), count: 4)
        payload += name
        return header(.request, .fileRange, UInt32(payload.count)) + payload + header(.acknowledgement, .fileRange)
    }
    private func exit() -> Data { header(.request, .exit) }
    private func make(_ bytes: Data, options: BackendSessionOptions = .init()) -> (BackendSession, Peer, Source) {
        let peer = Peer(bytes)
        let source = Source()
        return (BackendSession(transport: peer, reader: source, options: options), peer, source)
    }
    private func fails(_ session: BackendSession, _ offers: [BackendFileOffer], as expected: BackendError,
                       file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await session.run(offers: offers); XCTFail("unexpected success", file: file, line: line) }
        catch let error as BackendError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    func testExactListUnicodeFramingAndExit() async throws {
        let name = Data(offer.name.utf8)
        let (session, peer, _) = make(header(.request, .list) + header(.acknowledgement, .list, 7) + range(name, 0, 10) + exit())
        let result = try await session.run(offers: [offer])
        let (writes, closes) = await peer.snapshot()
        XCTAssertEqual(writes, [header(.response, .list, UInt32(name.count + 1)), name + Data([10]),
                                header(.acknowledgement, .fileRange, UInt32(16 + name.count)),
                                header(.response, .fileRange, 10), Data(repeating: 0x42, count: 10), header(.response, .exit)])
        XCTAssertEqual(closes, 1)
        XCTAssertEqual(result.files[0].phase, .transferredAwaitingConfirmation)
        XCTAssertEqual(result.totalBytesSent, 10)
        await fails(session, [offer], as: .busy)
    }

    func testOverlapAndEarlyExit() async throws {
        let n = Data(offer.name.utf8)
        let (session, _, _) = make(range(n, 0, 5) + range(n, 2, 5) + range(n, 0, 5) + exit())
        let result = try await session.run(offers: [offer, .init(id: "other", name: "other", byteCount: 0)])
        XCTAssertEqual(result.totalBytesSent, 15)
        XCTAssertEqual(result.files[0].uniqueBytesSent, 7)
        XCTAssertEqual(result.files[0].phase, .partiallyTransferred)
        XCTAssertEqual(result.files[1].phase, .notRequested)
    }

    func testInvalidFramingACKAndLengths() async {
        let n = Data(offer.name.utf8)
        let badMagic = Data([0, 1, 2, 3]) + exit().dropFirst(4)
        let cases: [Data] = [badMagic, header(.response, .exit),
                             Data([68,66,73,48]) + little(99, count: 4) + little(0, count: 8),
                             Data([68,66,73,48]) + little(0, count: 4) + little(1, count: 4) + little(0, count: 4),
                             header(.request, .list, 1), header(.request, .fileRange, 65_537),
                             header(.request, .list) + header(.response, .list),
                             header(.request, .list) + header(.acknowledgement, .exit),
                             range(n, 0, 1).dropLast(16) + header(.response, .fileRange)]
        for (index, bytes) in cases.enumerated() {
            let (session, peer, _) = make(bytes)
            await fails(session, [offer], as: index == 3 ? .unsupportedCommand : .protocolViolation)
            let (_, closes) = await peer.snapshot()
            XCTAssertEqual(closes, 1)
        }
    }

    func testAcknowledgmentLengthIsIgnoredAndTypeCommandStillChecked() async throws {
        let n = Data(offer.name.utf8)
        // The official host ignores the ACK length field entirely; a DBI build may
        // echo a 1 MiB-级 range size here, so any UInt32 length must be tolerated.
        let (tolerant, _, _) = make(header(.request, .list) + header(.acknowledgement, .list, UInt32.max) +
                                    range(n, 0, 10) + exit())
        let result = try await tolerant.run(offers: [offer])
        XCTAssertEqual(result.totalBytesSent, 10)

        let (badType, _, _) = make(header(.request, .list) + header(.response, .list))
        await fails(badType, [offer], as: .protocolViolation)
        let (badCommand, _, _) = make(header(.request, .list) + header(.acknowledgement, .exit))
        await fails(badCommand, [offer], as: .protocolViolation)
    }

    func testNamesRangesAndPlans() async {
        let n = Data(offer.name.utf8)
        let cases: [(Data, BackendError)] = [
            (range(Data("missing".utf8), 0, 1), .unknownFile),
            (range(n, 9, 2), .rangeOutOfBounds),
            (range(n, UInt64.max, 2), .rangeOutOfBounds),
            (range(Data([0xff]), 0, 1), .protocolViolation),
            (range(Data("../evil".utf8), 0, 1), .protocolViolation)
        ]
        for (bytes, expected) in cases {
            let (session, _, _) = make(bytes)
            await fails(session, [offer], as: expected)
        }
        for bad in ["x\ny", "../bad", "a\\b", "", "a\u{0000}b"] {
            let (session, _, _) = make(exit())
            await fails(session, [.init(id: "x", name: bad, byteCount: 1)], as: .invalidPlan)
        }
        let (duplicate, _, _) = make(exit())
        await fails(duplicate, [offer, .init(id: "new", name: offer.name, byteCount: 1)], as: .invalidPlan)
    }

    func testTimeoutEmptyReadShortSourceAndCloseFailure() async {
        let (emptySession, emptyPeer, _) = make(exit())
        await emptyPeer.setEmpty()
        await fails(emptySession, [offer], as: .protocolViolation)
        let (timeoutSession, timeoutPeer, _) = make(Data())
        await fails(timeoutSession, [offer], as: .timeout)
        let (_, timeoutCloses) = await timeoutPeer.snapshot()
        XCTAssertEqual(timeoutCloses, 1)
        let (shortSession, _, shortSource) = make(range(Data(offer.name.utf8), 0, 3))
        await shortSource.setShort()
        await fails(shortSession, [offer], as: .shortRead)
        let (closeSession, closePeer, _) = make(exit())
        await closePeer.setFailure()
        await fails(closeSession, [offer], as: .releaseUnverified)
        let (_, closeCalls) = await closePeer.snapshot()
        XCTAssertEqual(closeCalls, 1, "successful body and failed close must not retry close")
        await fails(closeSession, [offer], as: .busy)
        let (failureSession, failurePeer, _) = make(Data())
        await failurePeer.setFailure()
        await fails(failureSession, [offer], as: .releaseUnverified)
        let (_, failureCloses) = await failurePeer.snapshot()
        XCTAssertEqual(failureCloses, 1, "failure and failed close must not retry close")
    }

    func testBoundedChunksAndMalformedRangePrefix() async throws {
        let n = Data(offer.name.utf8)
        let options = BackendSessionOptions(maximumChunkSize: 2)
        let (session, peer, _) = make(range(n, 0, 5) + exit(), options: options)
        let result = try await session.run(offers: [offer])
        XCTAssertEqual(result.files[0].uniqueBytesSent, 5)
        let (writes, _) = await peer.snapshot()
        XCTAssertEqual(writes.filter { $0 == Data(repeating: 0x42, count: 2) }.count, 2)
        XCTAssertTrue(writes.contains(Data([0x42])))
        var payload = little(1, count: 4) + little(0, count: 8) + little(99, count: 4) + n
        let (bad, _, _) = make(header(.request, .fileRange, UInt32(payload.count)) + payload)
        await fails(bad, [offer], as: .protocolViolation)
        payload = little(1, count: 4) + little(0, count: 8) + little(UInt64(n.count), count: 4) + n
        let (oversizeList, _, _) = make(exit(), options: BackendSessionOptions(maximumCommandPayload: 17))
        await fails(oversizeList, [offer], as: .invalidPlan)
        let (commandBudget, _, _) = make(header(.request, .list) + header(.acknowledgement, .list),
                                         options: BackendSessionOptions(maximumCommands: 1))
        await fails(commandBudget, [offer], as: .timeout)
    }

    func testProgressPrecedesLaterProtocolFailureAndOverlapIsUnique() async throws {
        let n = Data(offer.name.utf8)
        let other = BackendFileOffer(id: "second", name: "second.nsp", byteCount: 2)
        let log = ProgressLog()
        let (session, peer, _) = make(range(n, 0, 5) + range(n, 2, 5) + range(n, 0, 5) +
                                      header(.response, .exit))
        do {
            _ = try await session.run(offers: [other, offer], onProgress: { try await log.record($0) })
            XCTFail("unexpected success")
        } catch let error as BackendError { XCTAssertEqual(error, .protocolViolation) }
        let snapshots = await log.values()
        XCTAssertEqual(snapshots.map(\.totalBytesSent), [5, 10, 15])
        XCTAssertEqual(snapshots.map { $0.files[1].uniqueBytesSent }, [5, 7, 7])
        XCTAssertTrue(snapshots.allSatisfy { !$0.peerRequestedExit && $0.files.map(\.fileID) == ["second", "file"] })
        XCTAssertTrue(snapshots.allSatisfy { $0.files[0].phase == .notRequested &&
            $0.files[1].phase == .partiallyTransferred })
        let (_, closes) = await peer.snapshot()
        XCTAssertEqual(closes, 1)
    }

    func testFullCoverageProgressIsHostOnlyBeforeExit() async throws {
        let n = Data(offer.name.utf8)
        let log = ProgressLog()
        let (session, peer, _) = make(range(n, 0, 10) + range(n, 0, 10) + exit())
        let result = try await session.run(offers: [offer], onProgress: { try await log.record($0) })
        let snapshots = await log.values()
        XCTAssertEqual(snapshots.map(\.totalBytesSent), [10, 20])
        XCTAssertEqual(snapshots.map { $0.files[0].uniqueBytesSent }, [10, 10])
        XCTAssertTrue(snapshots.allSatisfy { !$0.peerRequestedExit &&
            $0.files[0].phase == .transferredAwaitingConfirmation })
        XCTAssertTrue(result.peerRequestedExit)
        XCTAssertEqual(result.files[0].phase, .transferredAwaitingConfirmation)
        let (_, closes) = await peer.snapshot()
        XCTAssertEqual(closes, 1)
    }

    func testObserverFailureClosesOnceAndPreservesError() async throws {
        let log = ProgressLog()
        await log.setFailure()
        let (session, peer, _) = make(range(Data(offer.name.utf8), 0, 3) + exit())
        do {
            _ = try await session.run(offers: [offer], onProgress: { try await log.record($0) })
            XCTFail("unexpected success")
        } catch let error as BackendError { XCTAssertEqual(error, .sourceChanged) }
        let snapshots = await log.values()
        XCTAssertEqual(snapshots.count, 1)
        let (_, closes) = await peer.snapshot()
        XCTAssertEqual(closes, 1)
        await fails(session, [offer], as: .busy)
    }

    func testCancellationAndReentrancy() async throws {
        let (session, peer, _) = make(exit())
        await peer.setPause()
        let offered = offer
        let task = Task { try await session.run(offers: [offered]) }
        try await Task.sleep(for: .milliseconds(30))
        await fails(session, [offer], as: .busy)
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled task succeeded") }
        catch let error as BackendError { XCTAssertEqual(error, .cancelled) }
        catch { XCTFail("unexpected \(error)") }
        let (_, closes) = await peer.snapshot()
        XCTAssertEqual(closes, 1)
    }
}
