import Foundation

/// Finite, cooperative budgets. A transport/reader must honor cancellation and its
/// finite timeout; Swift cannot forcibly close a non-cooperative blocked operation.
public struct BackendSessionOptions: Sendable {
    public let operationTimeoutMilliseconds: UInt32
    public let sessionTimeoutMilliseconds: UInt32
    public let maximumCommandPayload: Int
    public let maximumChunkSize: Int
    public let maximumCommands: Int

    public init(operationTimeoutMilliseconds: UInt32 = 5_000,
                sessionTimeoutMilliseconds: UInt32 = 120_000,
                maximumCommandPayload: Int = 65_536,
                maximumChunkSize: Int = 65_536,
                maximumCommands: Int = 4_096) {
        self.operationTimeoutMilliseconds = operationTimeoutMilliseconds
        self.sessionTimeoutMilliseconds = sessionTimeoutMilliseconds
        self.maximumCommandPayload = maximumCommandPayload
        self.maximumChunkSize = maximumChunkSize
        self.maximumCommands = maximumCommands
    }

    var valid: Bool {
        operationTimeoutMilliseconds > 0 && sessionTimeoutMilliseconds > 0 &&
        maximumCommandPayload >= BackendCodec.rangePrefixSize + 1 &&
        maximumCommandPayload <= 1_048_576 && maximumChunkSize > 0 &&
        maximumChunkSize <= 1_048_576 && maximumCommands > 0 && maximumCommands <= 100_000
    }
}

/// Called after each successful host file-data write with a conservative snapshot.
/// A throwing observer aborts the session; the transport is still closed once.
/// A crash between transport write and observer persistence can leave progress unknown.
public typealias BackendProgressObserver = @Sendable (BackendTransferResult) async throws -> Void

/// One-shot DBI Backend host session over an already opened byte transport.
/// Never discovers a device, selects an install destination, or confirms installation.
public actor BackendSession {
    private let transport: any BackendByteTransport
    private let reader: any BackendFileReading
    private let options: BackendSessionOptions
    private var started = false

    public init(transport: any BackendByteTransport, reader: any BackendFileReading,
                options: BackendSessionOptions = .init()) {
        self.transport = transport
        self.reader = reader
        self.options = options
    }

    public func run(offers: [BackendFileOffer],
                    onProgress: BackendProgressObserver? = nil) async throws -> BackendTransferResult {
        guard !started else { throw BackendError.busy }
        started = true // No reuse, even when validation or close fails.
        let outcome: Result<BackendTransferResult, Error>
        do {
            outcome = .success(try await runBody(offers: offers, onProgress: onProgress))
        } catch {
            outcome = .failure(error is CancellationError || Task.isCancelled ? BackendError.cancelled : error)
        }
        // Close exactly once, regardless of body outcome. A failed release takes
        // precedence because the device ownership state is then unverified.
        do { try await transport.close() } catch { throw BackendError.releaseUnverified }
        if case .success = outcome, Task.isCancelled { throw BackendError.cancelled }
        return try outcome.get()
    }

    private func runBody(offers: [BackendFileOffer],
                         onProgress: BackendProgressObserver?) async throws -> BackendTransferResult {
            guard options.valid else { throw BackendError.invalidPlan }
            var names: [Data: BackendFileOffer] = [:]
            var ids: Set<String> = []
            var listing = Data()
            for offer in offers {
                guard BackendCodec.validName(offer.name), !offer.id.isEmpty,
                      ids.insert(offer.id).inserted else { throw BackendError.invalidPlan }
                let name = Data(offer.name.utf8)
                guard names.updateValue(offer, forKey: name) == nil,
                      name.count <= options.maximumCommandPayload - BackendCodec.rangePrefixSize,
                      listing.count <= options.maximumCommandPayload - name.count - 1 else {
                    throw BackendError.invalidPlan
                }
                listing.append(name)
                listing.append(0x0a)
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .milliseconds(Int(options.sessionTimeoutMilliseconds)))
            var coverage: [String: Coverage] = [:]
            var total: UInt64 = 0
            var exited = false
            for _ in 0..<options.maximumCommands {
                let header = try await readHeader(clock: clock, deadline: deadline)
                guard header.type == .request else { throw BackendError.protocolViolation }
                switch header.command {
                case .exit:
                    guard header.payloadSize == 0 else { throw BackendError.protocolViolation }
                    try await write(BackendCodec.Header(type: .response, command: .exit, payloadSize: 0).encoded(), clock: clock, deadline: deadline)
                    exited = true
                case .list:
                    guard header.payloadSize == 0 else { throw BackendError.protocolViolation }
                    try await write(BackendCodec.Header(type: .response, command: .list, payloadSize: UInt32(listing.count)).encoded(), clock: clock, deadline: deadline)
                    if !listing.isEmpty {
                        try await acknowledge(.list, clock: clock, deadline: deadline)
                        try await write(listing, clock: clock, deadline: deadline)
                    }
                case .fileRange:
                    let length = Int(header.payloadSize)
                    guard length > BackendCodec.rangePrefixSize,
                          length <= options.maximumCommandPayload else { throw BackendError.protocolViolation }
                    // The official host ACKs the request header before receiving its payload.
                    try await write(BackendCodec.Header(type: .acknowledgement, command: .fileRange, payloadSize: header.payloadSize).encoded(), clock: clock, deadline: deadline)
                    let payload = try await readExactly(length, clock: clock, deadline: deadline)
                    let range = try BackendCodec.decodeRange(payload)
                    guard let offer = names[range.nameBytes] else { throw BackendError.unknownFile }
                    let (end, overflow) = range.offset.addingReportingOverflow(UInt64(range.size))
                    guard !overflow, end <= offer.byteCount else { throw BackendError.rangeOutOfBounds }
                    try await write(BackendCodec.Header(type: .response, command: .fileRange, payloadSize: range.size).encoded(), clock: clock, deadline: deadline)
                    try await acknowledge(.fileRange, clock: clock, deadline: deadline)
                    var offset = range.offset
                    while offset < end {
                        let chunk = Int(min(UInt64(options.maximumChunkSize), end - offset))
                        try checkBudget(clock: clock, deadline: deadline)
                        let bytes = try await reader.read(fileID: offer.id, offset: offset, length: chunk)
                        try checkBudget(clock: clock, deadline: deadline)
                        guard bytes.count == chunk else { throw BackendError.shortRead }
                        let (sum, sumOverflow) = total.addingReportingOverflow(UInt64(chunk))
                        guard !sumOverflow else { throw BackendError.protocolViolation }
                        // Do not omit coverage merely because a post-write deadline
                        // expires; the peer may have received the entire chunk.
                        try await transport.write(bytes, timeoutMilliseconds: timeout(clock: clock, deadline: deadline))
                        offset += UInt64(chunk)
                        total = sum
                        var intervals = coverage[offer.id] ?? Coverage()
                        intervals.add(offset - UInt64(chunk), offset)
                        coverage[offer.id] = intervals
                        if let onProgress {
                            try await onProgress(snapshot(offers: offers, coverage: coverage,
                                                          total: total, exited: false))
                        }
                        try checkBudget(clock: clock, deadline: deadline)
                    }
                }
                if exited { break }
            }
            guard exited else { throw BackendError.timeout }
            return snapshot(offers: offers, coverage: coverage, total: total, exited: true)
    }

    private func snapshot(offers: [BackendFileOffer], coverage: [String: Coverage],
                          total: UInt64, exited: Bool) -> BackendTransferResult {
        let files = offers.map { offer -> BackendFileTransfer in
            let bytes = coverage[offer.id]?.count ?? 0
            let phase: BackendFileTransferPhase = bytes == offer.byteCount && coverage[offer.id] != nil
                ? .transferredAwaitingConfirmation
                : (bytes == 0 ? .notRequested : .partiallyTransferred)
            return BackendFileTransfer(fileID: offer.id, byteCount: offer.byteCount,
                                       uniqueBytesSent: bytes, phase: phase)
        }
        return BackendTransferResult(files: files, peerRequestedExit: exited, totalBytesSent: total)
    }

    private func checkBudget(clock: ContinuousClock, deadline: ContinuousClock.Instant) throws {
        if Task.isCancelled { throw BackendError.cancelled }
        if clock.now >= deadline { throw BackendError.timeout }
    }

    private func timeout(clock: ContinuousClock, deadline: ContinuousClock.Instant) throws -> UInt32 {
        try checkBudget(clock: clock, deadline: deadline)
        let remaining = clock.now.duration(to: deadline).components
        let millis = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
        guard millis > 0 else { throw BackendError.timeout }
        return UInt32(min(Int64(options.operationTimeoutMilliseconds), millis))
    }

    private func readExactly(_ length: Int, clock: ContinuousClock, deadline: ContinuousClock.Instant) async throws -> Data {
        var result = Data()
        while result.count < length {
            let part = try await transport.read(maximumLength: length - result.count,
                                                timeoutMilliseconds: timeout(clock: clock, deadline: deadline))
            try checkBudget(clock: clock, deadline: deadline)
            guard !part.isEmpty, part.count <= length - result.count else { throw BackendError.protocolViolation }
            result.append(part)
        }
        return result
    }

    private func readHeader(clock: ContinuousClock, deadline: ContinuousClock.Instant) async throws -> BackendCodec.Header {
        try BackendCodec.decodeHeader(await readExactly(BackendCodec.headerSize, clock: clock, deadline: deadline))
    }

    private func acknowledge(_ command: BackendCodec.Command, clock: ContinuousClock,
                             deadline: ContinuousClock.Instant) async throws {
        let ack = try await readHeader(clock: clock, deadline: deadline)
        guard ack.type == .acknowledgement, ack.command == command,
              Int(ack.payloadSize) <= options.maximumCommandPayload else { throw BackendError.protocolViolation }
        // The pinned host script reads only the ACK header and ignores its length
        // field; it does not read an ACK payload or assert an echoed size.
    }

    private func write(_ bytes: Data, clock: ContinuousClock, deadline: ContinuousClock.Instant) async throws {
        try await transport.write(bytes, timeoutMilliseconds: timeout(clock: clock, deadline: deadline))
        try checkBudget(clock: clock, deadline: deadline)
    }
}

private struct Coverage {
    private var spans: [Range<UInt64>] = []
    var count: UInt64 { spans.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    mutating func add(_ start: UInt64, _ end: UInt64) {
        guard start < end else { return }
        var lower = start
        var upper = end
        var merged: [Range<UInt64>] = []
        for span in spans {
            if span.upperBound < lower || upper < span.lowerBound {
                merged.append(span)
            } else {
                lower = min(lower, span.lowerBound)
                upper = max(upper, span.upperBound)
            }
        }
        merged.append(lower..<upper)
        spans = merged.sorted { $0.lowerBound < $1.lowerBound }
    }
}
