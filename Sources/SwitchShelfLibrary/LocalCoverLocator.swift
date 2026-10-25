import Foundation

/// A regular image file observed while scanning. The scan records its size and
/// location only; it does not read the bytes.
public struct CoverCandidate: Sendable, Equatable {
    public var url: URL
    public var byteCount: Int64
    public var relativeDirectory: String

    public init(url: URL, byteCount: Int64, relativeDirectory: String) {
        self.url = url
        self.byteCount = byteCount
        self.relativeDirectory = relativeDirectory
    }
}

/// Chooses one local sidecar image for a game directory.
///
/// Recognized names are `cover`, `poster`, `boxart`, `folder`, `artwork` and `icon`.
/// The file must sit in the game directory, or in one immediate artwork folder under it.
/// This does not download artwork and does not open NSP/XCI/NSZ/XCZ bytes.
public enum LocalCoverLocator {
    public static let maximumByteCount: Int64 = 20 * 1024 * 1024

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff"]
    private static let stemRank: [String: Int] = [
        "cover": 0,
        "poster": 1,
        "boxart": 2,
        "folder": 3,
        "artwork": 4,
        "icon": 5
    ]
    private static let artworkFolders: Set<String> = ["images", "image", "artwork", "covers", "cover", "art"]

    public static func accepts(byteCount: Int64) -> Bool {
        byteCount > 0 && byteCount <= maximumByteCount
    }

    public static func isSidecarFilename(_ filename: String) -> Bool {
        guard !filename.hasPrefix("."), !filename.hasPrefix("._") else { return false }
        return stemRank(filename) != nil
    }

    /// Best candidate for `gameDirectory`, or nil when none qualifies.
    public static func select(_ candidates: [CoverCandidate], gameDirectory: String) -> URL? {
        guard !gameDirectory.isEmpty, !gameDirectory.contains("..") else { return nil }
        let ranked = candidates.compactMap { candidate -> (url: URL, rank: Int, depth: Int)? in
            guard accepts(byteCount: candidate.byteCount),
                  isWithin(candidate.relativeDirectory, gameDirectory: gameDirectory),
                  let rank = stemRank(candidate.url.lastPathComponent) else { return nil }
            return (candidate.url, rank, candidate.relativeDirectory.split(separator: "/").count)
        }
        return ranked.min { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.url.path < rhs.url.path
        }?.url
    }

    private static func stemRank(_ filename: String) -> Int? {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return nil }
        return stemRank[stem]
    }

    private static func isWithin(_ relativeDirectory: String, gameDirectory: String) -> Bool {
        guard !relativeDirectory.contains(".."), !relativeDirectory.hasPrefix("/") else { return false }
        if relativeDirectory == gameDirectory { return true }
        let prefix = gameDirectory + "/"
        guard relativeDirectory.hasPrefix(prefix) else { return false }
        let remainder = String(relativeDirectory.dropFirst(prefix.count))
        return !remainder.contains("/") && artworkFolders.contains(remainder.lowercased())
    }
}
