import Foundation
import SwitchShelfDomain

/// Recognizes the early UI prototype's JSON snapshot stored at `library.sqlite`.
/// A valid legacy file is moved to a unique backup before SQLite creates its DB;
/// unrecognized/corrupt files are left untouched for manual recovery.
public enum LibraryCacheMigration {
    public static func moveLegacyJSONAside(at databaseURL: URL) throws -> LibrarySnapshot? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: databaseURL.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: databaseURL)
        let header: Data
        do { header = try handle.read(upToCount: 16) ?? Data() }
        catch { try? handle.close(); throw error }
        try handle.close()
        if header == Data("SQLite format 3\0".utf8) { return nil }

        let attributes = try manager.attributesOfItem(atPath: databaseURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= 16 * 1024 * 1024 else {
            throw LegacyCacheError.unrecognized
        }
        let snapshot: LibrarySnapshot
        do { snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: databaseURL)) }
        catch { throw LegacyCacheError.unrecognized }
        let backup = databaseURL.appendingPathExtension("legacy-json-\(UUID().uuidString)")
        try manager.moveItem(at: databaseURL, to: backup)
        return snapshot
    }
}

public enum LegacyCacheError: Error, LocalizedError {
    case unrecognized
    public var errorDescription: String? {
        "缓存不是可识别的 SQLite 或旧版 JSON；原文件未改动，请备份后手动检查。"
    }
}
