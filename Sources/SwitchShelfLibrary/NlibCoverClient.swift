import Foundation
import SwitchShelfDomain

/// Loads a square cover from the public Nlib API (`https://api.nlib.cc`).
///
/// Nlib hosts the JPEG itself. A filename Title ID is still only a candidate:
/// a successful image does not verify the package. Local sidecar files win
/// over this lookup. Unknown IDs, transport failures and undecodable responses
/// produce no image.
public enum NlibCoverClient: Sendable {
    public static let iconPixel = 480
    public static let maximumByteCount = 2 * 1024 * 1024
    public static let userAgent = "SwitchShelf/1.0"

    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: RedirectGuard.shared, delegateQueue: nil)
    }()

    /// Base Title ID Nlib can illustrate, or nil when the game has none.
    /// Update IDs ending in `800` use the paired base ID ending in `000`.
    public static func titleID(for game: Game) -> String? {
        var ids: [String] = []
        if let id = canonicalTitleID(game.id) { ids.append(id) }
        for content in game.contents {
            if let id = content.titleID.flatMap(canonicalTitleID) { ids.append(id) }
        }
        if let base = ids.first(where: { $0.hasSuffix("000") }) { return base }
        if let update = ids.first(where: { $0.hasSuffix("800") }) {
            return String(update.dropLast(3)) + "000"
        }
        return nil
    }

    public static func canonicalTitleID(_ raw: String) -> String? {
        let titleID = raw.uppercased()
        guard titleID.count == 16, titleID.allSatisfy(\.isHexDigit), titleID.hasPrefix("01") else { return nil }
        return titleID
    }

    public static func iconURL(for titleID: String) -> URL? {
        guard let titleID = canonicalTitleID(titleID) else { return nil }
        return URL(string: "https://api.nlib.cc/nx/\(titleID)/icon/\(iconPixel)")
    }

    public static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.host?.lowercased() == "api.nlib.cc" else { return false }
        guard url.user == nil, url.password == nil, url.port == nil else { return false }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "nx", parts[2] == "icon", parts[3] == String(iconPixel) else { return false }
        return canonicalTitleID(parts[1]) == parts[1]
    }

    /// Downloads one icon and returns a bounded thumbnail. The session is injectable for tests.
    public static func thumbnail(
        for titleID: String,
        session: URLSession = NlibCoverClient.session,
        maximumByteCount: Int = NlibCoverClient.maximumByteCount
    ) async -> CoverThumbnail? {
        guard maximumByteCount > 0, let url = iconURL(for: titleID), allows(url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  allows(http.url ?? url),
                  data.count <= maximumByteCount else { return nil }
            return CoverImageLoader.thumbnail(from: data)
        } catch {
            return nil
        }
    }
}

/// Shares one download per Title ID and keeps at most four requests in flight.
public actor NlibCoverFetcher {
    public static let shared = NlibCoverFetcher()

    private let session: URLSession
    private let limit = 4
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<CoverThumbnail?, Never>] = [:]

    public init(session: URLSession = NlibCoverClient.session) {
        self.session = session
    }

    public func thumbnail(for titleID: String) async -> CoverThumbnail? {
        guard let normalized = NlibCoverClient.canonicalTitleID(titleID) else { return nil }
        if let existing = inFlight[normalized] {
            return await existing.value
        }
        await acquireSlot()
        let session = self.session
        let task = Task<CoverThumbnail?, Never> {
            await NlibCoverClient.thumbnail(for: normalized, session: session)
        }
        inFlight[normalized] = task
        defer {
            inFlight[normalized] = nil
            releaseSlot()
        }
        return await task.value
    }

    private func acquireSlot() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = RedirectGuard()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard NlibCoverClient.allows(request.url) else { return nil }
        return request
    }
}
