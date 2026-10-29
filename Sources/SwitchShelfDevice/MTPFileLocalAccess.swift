import Darwin
import Foundation

/// Metadata pinned by the UI before the helper starts. This is file authority,
/// not package identification or installation evidence.
public struct MTPFileUploadSource: Codable, Sendable, Equatable {
    public let url: URL
    public let byteCount: UInt64
    let identity: MTPFileLocalIdentity
    public static func review(_ url: URL) throws -> Self {
        guard !["nsp", "xci", "nsz", "xcz"].contains(url.pathExtension.lowercased()) else { throw MTPFileError.uploadNotAllowed }
        try MTPFileLocalAccess.validateURL(url)
        let value = try MTPFileLocalIdentity.capture(url)
        return Self(url: url, byteCount: UInt64(value.size), identity: value)
    }
}

struct MTPFileLocalIdentity: Codable, Sendable, Equatable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; size = info.st_size
        modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
    }
    static func capture(_ url: URL) throws -> Self {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size >= 0 else { throw MTPFileError.localAccess }
        return Self(info)
    }
}

enum MTPFileLocalAccess {
    static let protectedRoot = "/Volumes/switch 游戏包"
    static func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0"),
              [nil, "", "localhost"].contains(url.host),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              url.path != protectedRoot, !url.path.hasPrefix(protectedRoot + "/") else {
            throw MTPFileError.localAccess
        }
        // realpath rejects every symlink component, not just the final file.
        guard let resolved = realpath(url.path, nil) else { throw MTPFileError.localAccess }
        defer { free(resolved) }
        guard String(cString: resolved) == url.path else { throw MTPFileError.localAccess }
    }
    static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw MTPFileError.localAccess }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw MTPFileError.localAccess }
        for component in path.split(separator: "/") {
            let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(current)
            guard next >= 0 else { throw MTPFileError.localAccess }
            current = next
        }
        return current
    }
    static func validateDestination(_ url: URL) throws {
        guard url.isFileURL, !url.path.contains("\0"), [nil, "", "localhost"].contains(url.host),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              MTPFileNames.isValid(url.lastPathComponent) else { throw MTPFileError.localAccess }
        try validateURL(url.deletingLastPathComponent())
        guard url.path != protectedRoot, !url.path.hasPrefix(protectedRoot + "/") else { throw MTPFileError.localAccess }
        var info = stat()
        if lstat(url.path, &info) == 0 { throw MTPFileError.destinationExists }
        guard errno == ENOENT else { throw MTPFileError.localAccess }
    }
}

/// This descriptor never opens with write access. Every bounded read verifies
/// size, inode and timestamps against both the review and opened descriptor.
final class MTPFilePinnedSource: @unchecked Sendable {
    private var descriptor: Int32 = -1
    private let source: MTPFileUploadSource
    var byteCount: UInt64 { source.byteCount }
    init(_ source: MTPFileUploadSource) throws {
        self.source = source
        try MTPFileLocalAccess.validateURL(source.url)
        guard try MTPFileLocalIdentity.capture(source.url) == source.identity else { throw MTPFileError.sourceChanged }
        let parent = try MTPFileLocalAccess.openDirectory(source.url.deletingLastPathComponent().path)
        defer { Darwin.close(parent) }
        descriptor = openat(parent, source.url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MTPFileError.localAccess }
        do { try validate() } catch { close(); throw error }
    }
    func validate() throws {
        try MTPFileLocalAccess.validateURL(source.url)
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0,
              MTPFileLocalIdentity(info) == source.identity,
              try MTPFileLocalIdentity.capture(source.url) == source.identity else { throw MTPFileError.sourceChanged }
    }
    func read(offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard count >= 0, count <= 1_048_576, offset <= byteCount,
              UInt64(count) <= byteCount - offset else { throw MTPFileError.localAccess }
        try validate()
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var position = 0
            while position < count {
                let amount = pread(descriptor, bytes.baseAddress!.advanced(by: position), count - position, off_t(offset) + off_t(position))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw MTPFileError.sourceChanged }
                position += amount
            }
        }
        try validate()
        return data
    }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}

/// A private partial file in the selected destination directory. It is published
/// with an atomic no-overwrite hard link only after complete verified download.
final class MTPFileDownloadSink: @unchecked Sendable {
    private var parent: Int32 = -1
    private var descriptor: Int32 = -1
    private let temporaryName = ".SwitchShelf-partial-" + UUID().uuidString
    private let destinationName: String
    private let destinationDirectory: URL
    private var committed = false
    private(set) var count: UInt64 = 0
    init(destination: URL) throws {
        destinationName = destination.lastPathComponent
        destinationDirectory = destination.deletingLastPathComponent()
        try MTPFileLocalAccess.validateDestination(destination)
        parent = try MTPFileLocalAccess.openDirectory(destination.deletingLastPathComponent().path)
        guard parent >= 0 else { throw MTPFileError.localAccess }
        descriptor = openat(parent, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { Darwin.close(parent); parent = -1; throw MTPFileError.localAccess }
    }
    func partialFile() throws -> MTPFilePartialFile {
        var info = stat()
        guard descriptor >= 0, fstat(descriptor, &info) == 0 else { throw MTPFileError.localAccess }
        return MTPFilePartialFile(url: destinationDirectory.appendingPathComponent(temporaryName), device: info.st_dev, inode: info.st_ino)
    }
    func write(_ bytes: Data) throws {
        try Task.checkCancellation()
        guard descriptor >= 0, bytes.count <= 1_048_576,
              UInt64(bytes.count) <= UInt64.max - count else { throw MTPFileError.localAccess }
        try bytes.withUnsafeBytes { buffer in
            var position = 0
            while position < bytes.count {
                let amount = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: position), bytes.count - position)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw MTPFileError.localAccess }
                position += amount
            }
        }
        count += UInt64(bytes.count)
    }
    func commit(expectedBytes: UInt64) throws {
        try Task.checkCancellation()
        guard !committed, count == expectedBytes, descriptor >= 0, fsync(descriptor) == 0 else { throw MTPFileError.incompleteTransfer }
        guard temporaryNameStillMatchesDescriptor() else { throw MTPFileError.localAccess }
        guard linkat(parent, temporaryName, parent, destinationName, 0) == 0 else {
            throw errno == EEXIST ? MTPFileError.destinationExists : MTPFileError.localAccess
        }
        // The selected final name is now present and complete. Never remove it
        // as cleanup, even if subsequent directory synchronization fails.
        committed = true
        _ = unlinkat(parent, temporaryName, 0)
        guard fsync(parent) == 0 else { throw MTPFileError.localAccess }
    }
    private func temporaryNameStillMatchesDescriptor() -> Bool {
        var opened = stat(), named = stat()
        return descriptor >= 0 && parent >= 0 && fstat(descriptor, &opened) == 0
            && fstatat(parent, temporaryName, &named, AT_SYMLINK_NOFOLLOW) == 0
            && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
            && named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }
    deinit {
        if temporaryNameStillMatchesDescriptor() { _ = unlinkat(parent, temporaryName, 0) }
        if descriptor >= 0 { Darwin.close(descriptor) }
        if parent >= 0 { Darwin.close(parent) }
    }
}

enum MTPFileNames {
    static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf16.count <= 254
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    static func validate(_ location: MTPFileLocation) throws {
        guard !location.storageName.isEmpty, location.storageName.utf16.count <= 254,
              location.components.count <= 32, location.components.allSatisfy(isValid) else { throw MTPFileError.invalidPath }
    }
    static func isWritableSD(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "microsd card"
    }
}

/// Only the direct parent may use this receipt after proving worker exit. The
/// inode check prevents cleanup from deleting a replaced file or final target.
public struct MTPFilePartialFile: Codable, Sendable {
    public let url: URL
    let device: dev_t
    let inode: ino_t
}
