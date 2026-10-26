import CryptoKit
import Foundation

/// Disk cache of derived thumbnails. Source artwork and user-supplied files are never deleted.
public final class CoverThumbnailStore: @unchecked Sendable {
    public let directory: URL
    public let byteLimit: Int64
    private let lock = NSLock()
    private let fileManager = FileManager.default

    public init(directory: URL, byteLimit: Int64 = 256 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    public func cachedThumbnail(for fileURL: URL, byteCount: Int64, modifiedAt: Date?) -> CoverThumbnail? {
        lock.lock()
        defer { lock.unlock() }
        guard cacheDirectoryIsSafe else { return nil }
        let fingerprint = metadataFingerprint(for: fileURL, byteCount: byteCount, modifiedAt: modifiedAt)
        if let record = readCache(at: latestCacheURL(for: fileURL)), record.fingerprint == fingerprint {
            return record.thumbnail
        }

        // Existing caches used a metadata-dependent filename. Migrate a successful
        // online hit so it will also be available by URL after an offline restart.
        let legacy = directory.appendingPathComponent(hex(fingerprint) + ".scover")
        guard let record = readCache(at: legacy) else { return nil }
        if saveLocked(record.thumbnail, for: fileURL, fingerprint: fingerprint) {
            try? fileManager.removeItem(at: legacy)
        }
        return record.thumbnail
    }

    /// Read the last derived local cover without accessing its source URL.
    /// Call only when source metadata is unavailable, never after an online decode
    /// failure: stale artwork must not hide a changed or corrupt online source.
    public func latestCachedThumbnail(for fileURL: URL) -> CoverThumbnail? {
        guard fileURL.isFileURL else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard cacheDirectoryIsSafe else { return nil }
        return readCache(at: latestCacheURL(for: fileURL))?.thumbnail
    }

    @discardableResult
    public func save(_ thumbnail: CoverThumbnail, for fileURL: URL, byteCount: Int64, modifiedAt: Date?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveLocked(thumbnail, for: fileURL,
                          fingerprint: metadataFingerprint(for: fileURL, byteCount: byteCount, modifiedAt: modifiedAt))
    }

    private func saveLocked(_ thumbnail: CoverThumbnail, for fileURL: URL, fingerprint: Data) -> Bool {
        let payload = Self.encode(thumbnail, fingerprint: fingerprint)
        guard byteLimit > 0, Int64(payload.count) <= byteLimit else { return false }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard cacheDirectoryIsSafe else { return false }
            let destination = latestCacheURL(for: fileURL)
            if let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               values.isSymbolicLink == true || values.isRegularFile != true {
                return false
            }
            guard evictingUntil(freeFor: Int64(payload.count), replacing: destination) else { return false }
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".scover.tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try payload.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    private var cacheDirectoryIsSafe: Bool {
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func latestCacheURL(for fileURL: URL) -> URL {
        let identity = fileURL.isFileURL ? fileURL.standardizedFileURL.path : fileURL.absoluteString
        let digest = Data(SHA256.hash(data: Data(identity.utf8)))
        return directory.appendingPathComponent(hex(digest) + ".latest.scover")
    }

    private func metadataFingerprint(for fileURL: URL, byteCount: Int64, modifiedAt: Date?) -> Data {
        let stamp = modifiedAt?.timeIntervalSince1970 ?? 0
        let identity = "\(fileURL.standardizedFileURL.path)\n\(byteCount)\n\(stamp)"
        return Data(SHA256.hash(data: Data(identity.utf8)))
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private struct Record {
        var thumbnail: CoverThumbnail
        var fingerprint: Data?
    }

    private func readCache(at destination: URL) -> Record? {
        guard let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let size = values.fileSize, size > 12, Int64(size) <= byteLimit,
              let data = try? Data(contentsOf: destination), Int64(data.count) <= byteLimit else { return nil }
        guard let record = Self.decode(data) else {
            try? fileManager.removeItem(at: destination)
            return nil
        }
        return record
    }

    private func evictingUntil(freeFor additional: Int64, replacing destination: URL) -> Bool {
        var entries = cacheEntries().filter { $0.url != destination }
        var used = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        while used + additional > byteLimit, !entries.isEmpty {
            let oldest = entries.removeFirst()
            guard oldest.isRegularFile else { return false }
            do {
                try fileManager.removeItem(at: oldest.url)
                used -= oldest.byteCount
            } catch {
                return false
            }
        }
        return used + additional <= byteLimit
    }

    private struct Entry {
        var url: URL
        var byteCount: Int64
        var modifiedAt: Date
        var isRegularFile: Bool
    }

    private func cacheEntries() -> [Entry] {
        guard let names = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey
        ]) else { return [] }
        return names.compactMap { url in
            guard url.pathExtension == "scover" else { return nil }
            guard let values = try? url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey
            ]) else { return nil }
            return Entry(
                url: url,
                byteCount: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast,
                isRegularFile: values.isSymbolicLink != true && values.isRegularFile == true
            )
        }
        .sorted { $0.modifiedAt < $1.modifiedAt }
    }

    private static func encode(_ thumbnail: CoverThumbnail, fingerprint: Data) -> Data {
        var data = Data("SCV2".utf8)
        append(UInt32(clamping: thumbnail.pixelWidth), to: &data)
        append(UInt32(clamping: thumbnail.pixelHeight), to: &data)
        data.append(fingerprint)
        data.append(thumbnail.jpegData)
        return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func decode(_ data: Data) -> Record? {
        let isCurrent = data.prefix(4) == Data("SCV2".utf8)
        let payloadOffset = isCurrent ? 44 : 12
        guard data.count > payloadOffset, isCurrent || data.prefix(4) == Data("SCVR".utf8) else { return nil }
        let width = readUInt32(data, at: 4)
        let height = readUInt32(data, at: 8)
        let jpeg = data.subdata(in: payloadOffset..<data.count)
        guard width > 0, height > 0, !jpeg.isEmpty else { return nil }
        return Record(thumbnail: CoverThumbnail(pixelWidth: Int(width), pixelHeight: Int(height), jpegData: jpeg),
                      fingerprint: isCurrent ? data.subdata(in: 12..<44) : nil)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
