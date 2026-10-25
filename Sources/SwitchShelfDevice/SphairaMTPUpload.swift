import Foundation

/// Hardware-free session seam. No production conformer is wired yet. A future adapter
/// must acquire DeviceLease before opening, inspect this same session (not cached
/// inventory), and retain the lease until close/independent process exit is verified.
struct SphairaUploadSession: Sendable {
    let deviceVersion: String
    let supportedOperations: Set<UInt16>
    let storages: [MTPStorage]
    /// Last transaction used while inspecting this same raw PTP session.
    let lastTransaction: UInt32

    func installStorage() throws -> UInt32 {
        let installNames: Set<String> = ["install", "install (nsp, xci, nsz, xcz, msp)"]
        func normalized(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let matches = storages.filter { installNames.contains(normalized($0.name)) }
        guard deviceVersion.lowercased().hasPrefix("sphaira/"),
              deviceVersion.count > "Sphaira/".count,
              supportedOperations.isSuperset(of: [0x9808, 0x100d]),
              storages.filter({ normalized($0.name) == "games" }).count == 1,
              Set(storages.map(\.id)).count == storages.count,
              matches.count == 1, let storage = matches.first,
              storage.id != 0, storage.id != UInt32.max else {
            throw SphairaUploadError.unsupportedSession
        }
        return storage.id
    }
}

/// A single raw PTP data phase spans beginData/writeData/endData. writeData must
/// not terminate the USB transfer at chunk boundaries (including with a short packet
/// or ZLP). endData performs the adapter's final packet/ZLP handling. No seeking,
/// SendPartialObject, DeleteObject, FormatStore or rollback is part of this contract.
protocol SphairaUploadTransport: Sendable {
    func inspectSession() async throws -> SphairaUploadSession
    func sendCommand(_ container: Data) async throws
    func beginData(_ header: Data) async throws
    func writeData(_ bytes: Data) async throws
    func endData() async throws
    func receiveResponse() async throws -> Data
    /// On interrupted transfers this must abort/release the session, not send another
    /// PTP command into the unfinished data phase. Must remain callable after cancellation.
    func close() async throws
}

/// Future production sources must open only a reviewed allowlisted path read-only,
/// reject symlinks/replacements, pin the descriptor and recheck its fingerprint.
/// Never implement this by materializing/copying/hashing an entire SMB package.
protocol SphairaUploadSource: Sendable {
    var byteCount: UInt64 { get }
    func validate() async throws
    func read(offset: UInt64, count: Int) async throws -> Data
}

struct SphairaUploadResult: Sendable, Equatable {
    enum Outcome: Sendable { case notStarted, deviceStateUnknown, transferredAwaitingConfirmation }
    enum Failure: Sendable { case cancelled, source, transport, protocolViolation, unsupportedSession, invalidRequest, alreadyUsed }
    let outcome: Outcome
    /// Host-side submission, NOT a device installation acknowledgment or resume offset.
    let bytesSubmitted: UInt64
    let failure: Failure?
    let releaseVerified: Bool
}

/// Single-file, single-use software foundation. Intentionally internal and unreachable
/// from the app/probe until the native streaming/deadline and reviewed field-test gates.
/// No retry, automatic resume, cleanup deletion or installed-state promotion occurs.
actor SphairaMTPUpload {
    private var used = false
    private let chunkSize: Int

    init(chunkSize: Int = 1024 * 1024) { self.chunkSize = chunkSize }

    func upload(name: String, from source: any SphairaUploadSource,
                through transport: any SphairaUploadTransport) async -> SphairaUploadResult {
        guard !used else {
            return .init(outcome: .notStarted, bytesSubmitted: 0, failure: .alreadyUsed, releaseVerified: false)
        }
        used = true
        var outcome = SphairaUploadResult.Outcome.notStarted
        var failure: SphairaUploadResult.Failure?
        var submitted: UInt64 = 0
        var sourceOperation = false
        let byteCount = source.byteCount
        do {
            try Task.checkCancellation()
            guard (1...4 * 1024 * 1024).contains(chunkSize),
                  SphairaPackageName.isValid(name), byteCount > 0,
                  byteCount <= UInt64(Int64.max) else { throw SphairaUploadError.invalidDataset }
            let session = try await transport.inspectSession()
            let storage = try session.installStorage()
            guard session.lastTransaction <= UInt32.max - 2 else { throw SphairaUploadError.invalidDataset }
            let createTransaction = session.lastTransaction + 1
            let sendTransaction = session.lastTransaction + 2
            try Task.checkCancellation()
            sourceOperation = true
            try await source.validate()
            sourceOperation = false
            let parameters = try SphairaUploadCodec.propertyParameters(storage: storage, byteCount: byteCount)
            let properties = try SphairaUploadCodec.filenameProperty(name)
            let create = try SphairaUploadCodec.command(.sendObjectPropList, parameters: parameters, transaction: createTransaction)
            try Task.checkCancellation()
            // The first command may have side effects even if its response is lost.
            outcome = .deviceStateUnknown
            try await transport.sendCommand(create)
            try await transport.beginData(SphairaUploadCodec.dataHeader(.sendObjectPropList,
                payloadBytes: UInt64(properties.count), transaction: createTransaction))
            try await transport.writeData(properties)
            try await transport.endData()
            let created = try SphairaUploadCodec.response(await transport.receiveResponse(), transaction: createTransaction, parameters: 3)
            guard created[0] == storage, created[1] == 0 || created[1] == storage,
                  created[2] != 0, created[2] != UInt32.max,
                  !session.storages.contains(where: { $0.id == created[2] }) else { throw SphairaUploadError.invalidResponse }
            try Task.checkCancellation()
            try await transport.sendCommand(SphairaUploadCodec.command(.sendObject, parameters: [], transaction: sendTransaction))
            try await transport.beginData(SphairaUploadCodec.dataHeader(.sendObject,
                payloadBytes: byteCount, transaction: sendTransaction))
            while submitted < byteCount {
                try Task.checkCancellation()
                let count = Int(min(UInt64(chunkSize), byteCount - submitted))
                sourceOperation = true
                try await source.validate()
                let bytes = try await source.read(offset: submitted, count: count)
                guard bytes.count == count else { throw SphairaUploadError.shortRead }
                try await source.validate()
                sourceOperation = false
                try Task.checkCancellation()
                try await transport.writeData(bytes)
                submitted += UInt64(count)
            }
            sourceOperation = true
            try await source.validate()
            sourceOperation = false
            try Task.checkCancellation()
            try await transport.endData()
            _ = try SphairaUploadCodec.response(await transport.receiveResponse(), transaction: sendTransaction, parameters: 0)
            // libhaze can respond before sphaira's installer has finished draining.
            outcome = .transferredAwaitingConfirmation
        } catch is CancellationError {
            failure = .cancelled
        } catch {
            if sourceOperation { failure = .source }
            else if let error = error as? SphairaUploadError {
                switch error {
                case .unsupportedSession: failure = .unsupportedSession
                case .invalidDataset, .invalidSource: failure = .invalidRequest
                default: failure = .protocolViolation
                }
            } else { failure = .transport }
        }
        var released = true
        do { try await transport.close() } catch { released = false }
        return .init(outcome: outcome, bytesSubmitted: submitted, failure: failure, releaseVerified: released)
    }
}
