import Darwin
import Foundation

/// Descriptor-pinned, bounded read-only package access for the future helper.
/// Not used by the app's metadata-only preflight. Blocking SMB operations must
/// eventually run in a separately supervised process, not an in-process timeout race.
actor SphairaPackageSource: SphairaUploadSource {
    private final class Descriptor: @unchecked Sendable {
        var value: Int32
        init(_ value: Int32) { self.value = value }
        func close() { if value >= 0 { Darwin.close(value); value = -1 } }
        deinit { close() }
    }
    let byteCount: UInt64
    private let url: URL
    private let descriptor: Descriptor
    private let fingerprint: SphairaSourceIdentity

    init(url: URL, allowedRoot: URL, expectedBytes: UInt64, reviewedIdentity: SphairaSourceIdentity? = nil) throws {
        guard url.isFileURL, allowedRoot.isFileURL,
              [nil, "", "localhost"].contains(url.host), [nil, "", "localhost"].contains(allowedRoot.host),
              !url.path.contains("\0"), !allowedRoot.path.contains("\0"),
              expectedBytes > 0, expectedBytes <= UInt64(Int64.max) else { throw SphairaUploadError.invalidSource }
        // Do not use standardizedFileURL here: on macOS it can rewrite an existing
        // /private/var path back to the /var symlink. Keep the reviewed spelling.
        let path = url.path
        let root = allowedRoot.path
        // Never accept traversal components or the whole filesystem as an allowlist.
        guard [path, root].allSatisfy({ value in
            value.hasPrefix("/") && !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        }), root != "/", path.hasPrefix(root + "/"), SphairaPackageName.isValid(url.lastPathComponent) else {
            throw SphairaUploadError.invalidSource
        }
        let fd = try Self.openWithoutSymlinks(path)
        let handle = Descriptor(fd)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_size > 0, UInt64(info.st_size) == expectedBytes else { throw SphairaUploadError.invalidSource }
        self.byteCount = expectedBytes
        self.url = url
        self.descriptor = handle
        self.fingerprint = SphairaSourceIdentity(info)
        if let reviewedIdentity, reviewedIdentity != self.fingerprint { throw SphairaUploadError.sourceChanged }
    }

    func validate() throws {
        guard descriptor.value >= 0 else { throw SphairaUploadError.invalidSource }
        let namedDescriptor: Int32
        do { namedDescriptor = try Self.openWithoutSymlinks(url.path) }
        catch { throw SphairaUploadError.sourceChanged }
        defer { Darwin.close(namedDescriptor) }
        var opened = stat()
        var named = stat()
        guard fstat(descriptor.value, &opened) == 0, fstat(namedDescriptor, &named) == 0,
              named.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              SphairaSourceIdentity(opened) == fingerprint, SphairaSourceIdentity(named) == fingerprint else {
            throw SphairaUploadError.sourceChanged
        }
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard count > 0, count <= 4 * 1024 * 1024, offset <= byteCount,
              UInt64(count) <= byteCount - offset else { throw SphairaUploadError.invalidSource }
        try validate()
        var data = Data(count: count)
        var completed = 0
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            while completed < count {
                try Task.checkCancellation()
                let read = pread(descriptor.value, buffer.baseAddress!.advanced(by: completed), count - completed,
                                 off_t(offset + UInt64(completed)))
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw SphairaUploadError.shortRead }
                completed += read
            }
        }
        try validate()
        return data
    }

    func close() { descriptor.close() }

    private static func openWithoutSymlinks(_ path: String) throws -> Int32 {
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw SphairaUploadError.invalidSource }
        var succeeded = false
        defer { if !succeeded { Darwin.close(current) } }
        let components = path.split(separator: "/")
        guard !components.isEmpty else { throw SphairaUploadError.invalidSource }
        for (index, component) in components.enumerated() {
            let directory = index < components.count - 1
            // O_NONBLOCK prevents a substituted FIFO from blocking before fstat rejects it.
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0)
            let next = String(component).withCString { openat(current, $0, flags) }
            guard next >= 0 else { throw SphairaUploadError.invalidSource }
            Darwin.close(current)
            current = next
        }
        succeeded = true
        return current
    }
}
