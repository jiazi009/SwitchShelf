import Darwin
import Foundation

/// A binding is created from an authoritative snapshot, never by interpreting the opaque ID.
public struct BackendSourceBinding: Sendable {
    public let id: String
    public let url: URL
    public let expectedBytes: UInt64

    public init(id: String, url: URL, expectedBytes: UInt64) {
        self.id = id
        self.url = url
        self.expectedBytes = expectedBytes
    }
}

/// Read-only, bounded POSIX range reader. Construct through `open` off the caller's actor.
public actor AllowlistedBackendFileReader: BackendFileReading {
    public static let maximumReadLength = 1_048_576

    private struct Evidence: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
        let ctimeSeconds: Int
        let ctimeNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            mtimeSeconds = value.st_mtimespec.tv_sec
            mtimeNanoseconds = value.st_mtimespec.tv_nsec
            ctimeSeconds = value.st_ctimespec.tv_sec
            ctimeNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    private struct Entry {
        let url: URL
        let expectedBytes: UInt64
        let evidence: Evidence
    }
    private var entries: [String: Entry] = [:]
    private init() {}

    /// Validates all bindings before making the allowlist available. No source bytes are read.
    public static func open(bindings: [BackendSourceBinding]) async throws -> AllowlistedBackendFileReader {
        let reader = AllowlistedBackendFileReader()
        try await reader.bind(bindings)
        return reader
    }

    private func bind(_ bindings: [BackendSourceBinding]) throws {
        try Self.requireNotCancelled()
        guard !bindings.isEmpty else { throw BackendError.invalidPlan }
        var prepared: [String: Entry] = [:]
        for binding in bindings {
            try Self.requireNotCancelled()
            guard !binding.id.isEmpty, prepared[binding.id] == nil,
                  binding.url.isFileURL, binding.expectedBytes <= UInt64(Int64.max) else {
                throw BackendError.invalidPlan
            }
            let fd = try Self.openWithoutSymlinks(binding.url)
            defer { close(fd) }
            let info = try Self.inspect(fd)
            try Self.requireNotCancelled()
            guard UInt64(info.st_size) == binding.expectedBytes else { throw BackendError.sourceChanged }
            prepared[binding.id] = Entry(url: binding.url, expectedBytes: binding.expectedBytes, evidence: Evidence(info))
        }
        try Self.requireNotCancelled()
        entries = prepared
    }

    public func read(fileID: String, offset: UInt64, length: Int) async throws -> Data {
        guard let entry = entries[fileID] else { throw BackendError.unknownFile }
        guard length > 0, length <= Self.maximumReadLength,
              offset <= entry.expectedBytes, UInt64(length) <= entry.expectedBytes - offset,
              offset <= UInt64(Int64.max) else { throw BackendError.rangeOutOfBounds }
        try Self.requireNotCancelled()
        let fd = try Self.openWithoutSymlinks(entry.url)
        defer { close(fd) }
        let before = try Self.inspect(fd)
        guard Evidence(before) == entry.evidence else { throw BackendError.sourceChanged }
        try Self.requireNotCancelled()
        var data = Data(count: length)
        let count: Int = data.withUnsafeMutableBytes { buffer in
            pread(fd, buffer.baseAddress!, length, off_t(offset))
        }
        try Self.requireNotCancelled()
        let after = try Self.inspect(fd)
        guard Evidence(after) == entry.evidence else { throw BackendError.sourceChanged }
        // Reopen by path as well: replacing a pathname while a descriptor is open
        // must not authorize bytes from the old, now-unbound file.
        let current = try Self.openWithoutSymlinks(entry.url)
        defer { close(current) }
        guard Evidence(try Self.inspect(current)) == entry.evidence else { throw BackendError.sourceChanged }
        if count < 0 { throw BackendError.unavailable }
        guard count == length else { throw BackendError.shortRead }
        return data
    }

    private static func requireNotCancelled() throws {
        if Task.isCancelled { throw BackendError.cancelled }
    }

    private static func inspect(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw BackendError.unavailable }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0,
              info.st_mode & 0o444 != 0 else { throw BackendError.sourceChanged }
        return info
    }

    /// Traverses every directory through O_NOFOLLOW; final component is O_NOFOLLOW too.
    /// Relative paths, `..` and symlink ancestors are never accepted.
    private static func openWithoutSymlinks(_ url: URL) throws -> Int32 {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else { throw BackendError.invalidPlan }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw BackendError.invalidPlan
        }
        var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw BackendError.unavailable }
        for (index, component) in components.enumerated() {
            let final = index == components.count - 1
            // O_NONBLOCK prevents a FIFO swapped into the final pathname from
            // hanging before fstat can reject it. It does not bound remote FS I/O.
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (final ? O_NONBLOCK : O_DIRECTORY)
            let next = component.withCString { openat(directory, $0, flags) }
            close(directory)
            if next < 0 {
                // A changed or inaccessible path is not a fallback to a different file.
                throw BackendError.sourceChanged
            }
            directory = next
        }
        return directory
    }
}
