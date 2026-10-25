import Darwin
import Foundation

public struct SphairaSourceIdentity: Codable, Sendable, Equatable {
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
        guard url.isFileURL, !url.path.contains("\0"), lstat(url.path, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_size > 0,
              let path = realpath(url.path, nil) else { throw SphairaUploadError.invalidSource }
        defer { free(path) }
        guard String(cString: path) == url.path else { throw SphairaUploadError.invalidSource }
        return Self(info)
    }
}

/// One immutable reviewed file, not the entire queue. No host target-setting command exists.
public struct SphairaInstallRequest: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let sourceURL: URL
    public let allowedRoot: URL
    public let byteCount: UInt64
    public let intendedTarget: String
    let identity: SphairaSourceIdentity
    public private(set) var userConfirmed: Bool

    /// Metadata-only review, off MainActor. Does not open USB or read package bytes.
    public static func review(sourceURL: URL, allowedRoot: URL, expectedBytes: UInt64,
                              intendedTarget: String) throws -> Self {
        guard expectedBytes > 0, expectedBytes <= UInt64(Int64.max),
              sourceURL.lastPathComponent != "", ["sd", "nand"].contains(intendedTarget),
              allowedRoot.isFileURL, allowedRoot.path != "/",
              sourceURL.path.hasPrefix(allowedRoot.path + "/"),
              SphairaPackageName.isValid(sourceURL.lastPathComponent) else { throw SphairaUploadError.invalidSource }
        let identity = try SphairaSourceIdentity.capture(sourceURL)
        guard identity.size == Int64(expectedBytes) else { throw SphairaUploadError.sourceChanged }
        return Self(id: UUID().uuidString, name: sourceURL.lastPathComponent, sourceURL: sourceURL,
                    allowedRoot: allowedRoot, byteCount: expectedBytes, intendedTarget: intendedTarget,
                    identity: identity, userConfirmed: false)
    }
    public func confirmed() -> Self { var copy = self; copy.userConfirmed = true; return copy }

    func validate() throws {
        guard UUID(uuidString: id) != nil, userConfirmed, name == sourceURL.lastPathComponent,
              ["sd", "nand"].contains(intendedTarget), identity.size > 0,
              UInt64(identity.size) == byteCount, SphairaPackageName.isValid(name),
              try SphairaSourceIdentity.capture(sourceURL) == identity else { throw SphairaUploadError.invalidSource }
    }
}

public struct SphairaInstallProgress: Codable, Sendable, Equatable {
    public let requestID: String
    public let phase: String
    public let bytesSubmitted: UInt64
    public let totalBytes: UInt64
    public let updatedAt: Date
}

public struct SphairaInstallReport: Codable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    public let transfer: SphairaUploadResult
    public let message: String
    public let processExitVerified: Bool
}

/// Owner-only, atomic + fsync state. A crash leaves last intent, never a fabricated success.
/// The supervisor stores its own exit verdict separately from the worker's USB-close verdict.
enum SphairaAttemptFile {
    static func save<T: Encodable>(_ value: T, at url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    static func load<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, info.st_size <= 65536 else { throw CocoaError(.fileReadCorruptFile) }
        let size = Int(info.st_size)
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < size {
                let count = pread(fd, buffer.baseAddress!.advanced(by: offset), size - offset, off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
                offset += count
            }
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
