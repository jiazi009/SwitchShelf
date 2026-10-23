import Darwin
import Foundation

public enum BackendJournalError: Error, Equatable, Sendable {
    case recoveryRequired
    case invalidTransition
    case invalidSnapshot
    case capacityExceeded
    case ioFailure
}

public enum BackendAttemptState: String, Codable, Sendable {
    case active, interrupted, finished, failed
}

public struct BackendJournalAttempt: Codable, Equatable, Sendable {
    public let id: UUID
    public let state: BackendAttemptState
    public let files: [BackendFileTransfer]
    public let totalBytesSent: UInt64
    public let peerRequestedExit: Bool
    public let startedAt: Date
    public let updatedAt: Date
}

private struct BackendJournalDocument: Codable {
    let schema: Int
    var attempts: [BackendJournalAttempt]
}

/// Local host-exchange evidence only: `finished` never means installed/confirmed.
/// A single actor serializes updates; use one journal owner per path.
public actor BackendTransferJournal {
    public static let maximumBytes = 1_048_576
    public static let maximumAttempts = 128
    public static let maximumFiles = 4_096

    private let url: URL
    private var document: BackendJournalDocument
    private var persistenceUncertain = false
    // Internal fault injection only; never a production bypass/reset API.
    private let afterRename: (@Sendable () throws -> Void)?

    private init(url: URL, document: BackendJournalDocument, afterRename: (@Sendable () throws -> Void)? = nil) {
        self.url = url
        self.document = document
        self.afterRename = afterRename
    }

    /// Unknown/corrupt/oversized files are never overwritten or reset implicitly.
    public static func open(at url: URL) async throws -> BackendTransferJournal {
        let journal = BackendTransferJournal(url: url, document: .init(schema: 1, attempts: []))
        try await journal.loadAndInterrupt()
        return journal
    }

    internal static func openForTesting(at url: URL, afterRename: @escaping @Sendable () throws -> Void) async throws -> BackendTransferJournal {
        let journal = BackendTransferJournal(url: url, document: .init(schema: 1, attempts: []), afterRename: afterRename)
        try await journal.loadAndInterrupt()
        return journal
    }

    public func attempts() -> [BackendJournalAttempt] { document.attempts }

    public func begin(id: UUID = UUID(), offers: [BackendFileOffer]) throws {
        guard !offers.isEmpty, offers.count <= Self.maximumFiles,
              !document.attempts.contains(where: { $0.id == id }),
              !document.attempts.contains(where: { $0.state == .active }) else {
            throw BackendJournalError.invalidTransition
        }
        guard document.attempts.count < Self.maximumAttempts else { throw BackendJournalError.capacityExceeded }
        var ids = Set<String>()
        guard offers.allSatisfy({ !$0.id.isEmpty && ids.insert($0.id).inserted }) else {
            throw BackendJournalError.invalidSnapshot
        }
        let now = Date()
        let files = offers.map { BackendFileTransfer(fileID: $0.id, byteCount: $0.byteCount, uniqueBytesSent: 0, phase: .notRequested) }
        let attempt = BackendJournalAttempt(id: id, state: .active, files: files, totalBytesSent: 0,
                                            peerRequestedExit: false, startedAt: now, updatedAt: now)
        var next = document
        next.attempts.append(attempt)
        try commit(next)
    }

    /// Suitable for `BackendProgressObserver`: each full snapshot is checked and atomically recorded.
    public func record(_ result: BackendTransferResult, attemptID: UUID) throws {
        guard let index = document.attempts.firstIndex(where: { $0.id == attemptID }),
              document.attempts[index].state == .active else { throw BackendJournalError.invalidTransition }
        let old = document.attempts[index]
        guard Self.valid(result.files, total: result.totalBytesSent), result.files.count == old.files.count,
              result.totalBytesSent >= old.totalBytesSent,
              (!old.peerRequestedExit || result.peerRequestedExit) else { throw BackendJournalError.invalidSnapshot }
        for (previous, current) in zip(old.files, result.files) {
            guard previous.fileID == current.fileID, previous.byteCount == current.byteCount,
                  current.uniqueBytesSent >= previous.uniqueBytesSent,
                  Self.rank(current.phase) >= Self.rank(previous.phase) else {
                throw BackendJournalError.invalidSnapshot
            }
        }
        guard let previousUnique = Self.uniqueSum(old.files),
              let currentUnique = Self.uniqueSum(result.files), currentUnique >= previousUnique,
              currentUnique - previousUnique <= result.totalBytesSent - old.totalBytesSent else {
            throw BackendJournalError.invalidSnapshot
        }
        var next = document
        next.attempts[index] = .init(id: old.id, state: .active, files: result.files,
                                     totalBytesSent: result.totalBytesSent, peerRequestedExit: result.peerRequestedExit,
                                     startedAt: old.startedAt, updatedAt: max(Date(), old.updatedAt))
        try commit(next)
    }

    public func end(attemptID: UUID, state: BackendAttemptState) throws {
        guard state == .interrupted || state == .failed || state == .finished,
              let index = document.attempts.firstIndex(where: { $0.id == attemptID }),
              document.attempts[index].state == .active,
              state != .finished || document.attempts[index].peerRequestedExit else {
            throw BackendJournalError.invalidTransition
        }
        var next = document
        let old = next.attempts[index]
        next.attempts[index] = .init(id: old.id, state: state, files: old.files,
                                     totalBytesSent: old.totalBytesSent, peerRequestedExit: old.peerRequestedExit,
                                     startedAt: old.startedAt, updatedAt: max(Date(), old.updatedAt))
        try commit(next)
    }

    private static func rank(_ phase: BackendFileTransferPhase) -> Int {
        switch phase {
        case .notRequested: 0
        case .partiallyTransferred: 1
        case .transferredAwaitingConfirmation: 2
        }
    }

    private static func uniqueSum(_ files: [BackendFileTransfer]) -> UInt64? {
        var sum: UInt64 = 0
        for file in files {
            let next = sum.addingReportingOverflow(file.uniqueBytesSent)
            guard !next.overflow else { return nil }
            sum = next.partialValue
        }
        return sum
    }

    private static func valid(_ files: [BackendFileTransfer], total: UInt64) -> Bool {
        guard !files.isEmpty, files.count <= maximumFiles else { return false }
        var ids = Set<String>()
        var uniqueTotal: UInt64 = 0
        let validFiles = files.allSatisfy { file in
            guard !file.fileID.isEmpty, ids.insert(file.fileID).inserted,
                  file.uniqueBytesSent <= file.byteCount else { return false }
            let sum = uniqueTotal.addingReportingOverflow(file.uniqueBytesSent)
            guard !sum.overflow else { return false }
            uniqueTotal = sum.partialValue
            switch file.phase {
            case .notRequested: return file.uniqueBytesSent == 0
            case .partiallyTransferred: return file.uniqueBytesSent > 0 && file.uniqueBytesSent < file.byteCount
            case .transferredAwaitingConfirmation: return file.uniqueBytesSent == file.byteCount
            }
        }
        return validFiles && total >= uniqueTotal
    }

    private func loadAndInterrupt() throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return }
            throw BackendJournalError.recoveryRequired
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              let bytes = Self.boundedRead(url),
              let loaded = try? JSONDecoder().decode(BackendJournalDocument.self, from: bytes),
              loaded.schema == 1, loaded.attempts.count <= Self.maximumAttempts,
              Set(loaded.attempts.map(\.id)).count == loaded.attempts.count,
              loaded.attempts.filter({ $0.state == .active }).count <= 1,
              loaded.attempts.allSatisfy({
                  Self.valid($0.files, total: $0.totalBytesSent) && $0.startedAt <= $0.updatedAt &&
                  ($0.state != .finished || $0.peerRequestedExit)
              }) else {
            throw BackendJournalError.recoveryRequired
        }
        var next = loaded
        for index in next.attempts.indices where next.attempts[index].state == .active {
            let old = next.attempts[index]
            next.attempts[index] = .init(id: old.id, state: .interrupted, files: old.files,
                                         totalBytesSent: old.totalBytesSent, peerRequestedExit: old.peerRequestedExit,
                                         startedAt: old.startedAt, updatedAt: max(Date(), old.updatedAt))
        }
        if next.attempts != loaded.attempts { try commit(next) }
        else { document = loaded }
    }

    private static func boundedRead(_ url: URL) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size >= 0, metadata.st_size <= maximumBytes else { return nil }
        var bytes = Data(count: maximumBytes + 1)
        let length = bytes.withUnsafeMutableBytes { buffer -> Int in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count < 0 { return -1 }
                if count == 0 { break }
                offset += count
            }
            return offset
        }
        guard length >= 0, length <= maximumBytes else { return nil }
        bytes.count = length
        return bytes
    }

    /// Writes a new inode, fsyncs it, renames atomically, then fsyncs the parent directory.
    /// In-memory state advances only after successful persistence.
    private func commit(_ next: BackendJournalDocument) throws {
        guard !persistenceUncertain else { throw BackendJournalError.recoveryRequired }
        guard let data = try? JSONEncoder().encode(next), data.count <= Self.maximumBytes else {
            throw BackendJournalError.capacityExceeded
        }
        let folder = url.deletingLastPathComponent()
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { throw BackendJournalError.ioFailure }
        let temporary = folder.appendingPathComponent(".backend-journal-\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BackendJournalError.ioFailure }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { try? FileManager.default.removeItem(at: temporary) }
        }
        let written = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0 && errno == EINTR { continue }
                if amount <= 0 { return false }
                offset += amount
            }
            return true
        }
        guard written, fsync(fd) == 0,
              rename(temporary.path, url.path) == 0 else { throw BackendJournalError.ioFailure }
        succeeded = true
        do { try afterRename?() }
        catch {
            persistenceUncertain = true
            throw BackendJournalError.ioFailure
        }
        let directory = Darwin.open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else {
            persistenceUncertain = true
            throw BackendJournalError.ioFailure
        }
        defer { close(directory) }
        guard fsync(directory) == 0 else {
            persistenceUncertain = true
            throw BackendJournalError.ioFailure
        }
        document = next
    }
}
