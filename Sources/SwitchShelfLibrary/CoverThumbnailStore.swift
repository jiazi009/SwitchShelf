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
        let destination = cacheURL(for: fileURL, byteCount: byteCount, modifiedAt: modifiedAt)
        guard let values = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              let data = try? Data(contentsOf: destination) else { return nil }
        guard let thumbnail = Self.decode(data) else {
            try? fileManager.removeItem(at: destination)
            return nil
        }
        return thumbnail
    }

    @discardableResult
    public func save(_ thumbnail: CoverThumbnail, for fileURL: URL, byteCount: Int64, modifiedAt: Date?) -> Bool {
        let payload = Self.encode(thumbnail)
        guard byteLimit > 0, Int64(payload.count) <= byteLimit else { return false }
        lock.lock()
        defer { lock.unlock() }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard evictingUntil(freeFor: Int64(payload.count)) else { return false }
            let destination = cacheURL(for: fileURL, byteCount: byteCount, modifiedAt: modifiedAt)
            if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                return false
            }
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".scover.tmp")
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

    private func cacheURL(for fileURL: URL, byteCount: Int64, modifiedAt: Date?) -> URL {
        let stamp = modifiedAt?.timeIntervalSince1970 ?? 0
        let identity = "\(fileURL.standardizedFileURL.path)\n\(byteCount)\n\(stamp)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".scover"
        return directory.appendingPathComponent(name)
    }

    private func evictingUntil(freeFor additional: Int64) -> Bool {
        var entries = cacheEntries()
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

    private static func encode(_ thumbnail: CoverThumbnail) -> Data {
        var data = Data("SCVR".utf8)
        append(UInt32(clamping: thumbnail.pixelWidth), to: &data)
        append(UInt32(clamping: thumbnail.pixelHeight), to: &data)
        data.append(thumbnail.jpegData)
        return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private static func decode(_ data: Data) -> CoverThumbnail? {
        guard data.count > 12, data.prefix(4) == Data("SCVR".utf8) else { return nil }
        let width = readUInt32(data, at: 4)
        let height = readUInt32(data, at: 8)
        let jpeg = data.subdata(in: 12..<data.count)
        guard width > 0, height > 0, !jpeg.isEmpty else { return nil }
        return CoverThumbnail(pixelWidth: Int(width), pixelHeight: Int(height), jpegData: jpeg)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
