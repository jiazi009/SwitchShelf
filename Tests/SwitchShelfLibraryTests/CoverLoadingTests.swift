import CoreGraphics
import Foundation
import ImageIO
import SwitchShelfDomain
import Testing
import UniformTypeIdentifiers
@testable import SwitchShelfLibrary

@Suite("Cover loading")
struct CoverLoadingTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelfCover_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSolidPNG(width: Int, height: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    @Test("Selects the preferred sidecar and ignores unrelated images")
    func selectsPreferredSidecar() {
        let game = "Zelda"
        let icon = CoverCandidate(url: URL(fileURLWithPath: "/library/Zelda/icon.png"), byteCount: 100, relativeDirectory: game)
        let poster = CoverCandidate(url: URL(fileURLWithPath: "/library/Zelda/images/poster.jpg"), byteCount: 200, relativeDirectory: "\(game)/images")
        let screenshot = CoverCandidate(url: URL(fileURLWithPath: "/library/Zelda/screenshot.png"), byteCount: 300, relativeDirectory: game)
        let buried = CoverCandidate(url: URL(fileURLWithPath: "/library/Zelda/images/extra/cover.png"), byteCount: 400, relativeDirectory: "\(game)/images/extra")
        let otherGame = CoverCandidate(url: URL(fileURLWithPath: "/library/Mario/cover.png"), byteCount: 500, relativeDirectory: "Mario")
        let huge = CoverCandidate(url: URL(fileURLWithPath: "/library/Zelda/cover.png"), byteCount: LocalCoverLocator.maximumByteCount + 1, relativeDirectory: game)

        let selected = LocalCoverLocator.select([icon, poster, screenshot, buried, otherGame, huge], gameDirectory: game)
        #expect(selected == poster.url)
    }

    @Test("Falls back to a square icon name when no poster exists")
    func fallsBackToIcon() {
        let icon = CoverCandidate(url: URL(fileURLWithPath: "/library/Zelda/icon.jpeg"), byteCount: 80, relativeDirectory: "Zelda")
        #expect(LocalCoverLocator.select([icon], gameDirectory: "Zelda") == icon.url)
        #expect(LocalCoverLocator.select([], gameDirectory: "Zelda") == nil)
        #expect(LocalCoverLocator.isSidecarFilename("cover.PNG"))
        #expect(!LocalCoverLocator.isSidecarFilename("screenshot.png"))
        #expect(!LocalCoverLocator.accepts(byteCount: 0))
    }

    @Test("Scan attaches only that game's sidecar and skips symlink covers")
    func scanAttachesLocalCover() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let zeldaBase = root.appendingPathComponent("Zelda/base/Zelda [0100111000000000][v0].nsp")
        let marioBase = root.appendingPathComponent("Mario/Mario [0100222000000000][v0].nsp")
        try FileManager.default.createDirectory(at: zeldaBase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: marioBase.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: zeldaBase)
        try Data(repeating: 1, count: 32).write(to: marioBase)
        let cover = root.appendingPathComponent("Zelda/cover.jpg")
        try Data(repeating: 2, count: 64).write(to: cover)
        let linked = root.appendingPathComponent("Mario/cover.jpg")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: cover)
        try Data(repeating: 3, count: 16).write(to: root.appendingPathComponent("Zelda/screenshot.png"))

        let snapshot = try await LibraryScanner().scan(LibrarySource(url: root, name: "Covers"))
        let zelda = try #require(snapshot.games.first { $0.title == "Zelda" })
        let mario = try #require(snapshot.games.first { $0.title == "Mario" })
        #expect(zelda.coverURL?.standardizedFileURL.path == cover.standardizedFileURL.path)
        #expect(mario.coverURL == nil)
        #expect(!zelda.contents.contains { $0.fileURL == cover })
        #expect(snapshot.games.allSatisfy { !$0.contents.contains { $0.fileURL.lastPathComponent == "screenshot.png" } })
    }

    @Test("Thumbnail keeps aspect and stays within the pixel bound")
    func thumbnailDecodesLocalImage() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let square = root.appendingPathComponent("icon.png")
        let poster = root.appendingPathComponent("cover.png")
        try writeSolidPNG(width: 800, height: 800, to: square)
        try writeSolidPNG(width: 300, height: 700, to: poster)

        let squareThumbnail = try #require(CoverImageLoader.thumbnail(at: square))
        let posterThumbnail = try #require(CoverImageLoader.thumbnail(at: poster))
        #expect(squareThumbnail.isSquare)
        #expect(!posterThumbnail.isSquare)
        #expect(max(squareThumbnail.pixelWidth, squareThumbnail.pixelHeight) <= CoverImageLoader.maxPixel)
        #expect(max(posterThumbnail.pixelWidth, posterThumbnail.pixelHeight) <= CoverImageLoader.maxPixel)
        #expect(squareThumbnail.pixelWidth > 0 && posterThumbnail.pixelHeight > posterThumbnail.pixelWidth)
    }

    @Test("Disk cache round-trips thumbnails and evicts only its own oldest files")
    func diskCacheEvictsOldestDerivedFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let store = CoverThumbnailStore(directory: cache, byteLimit: 650)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let keeper = cache.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: keeper)

        func thumbnail(_ byte: UInt8) -> CoverThumbnail {
            CoverThumbnail(pixelWidth: 12, pixelHeight: 20, jpegData: Data(repeating: byte, count: 300))
        }
        let first = root.appendingPathComponent("a.png")
        let second = root.appendingPathComponent("b.png")
        let third = root.appendingPathComponent("c.png")
        #expect(store.save(thumbnail(1), for: first, byteCount: 10, modifiedAt: Date(timeIntervalSince1970: 10)))
        try setModified(cache, jpegByte: 1, to: Date(timeIntervalSince1970: 10))
        #expect(store.save(thumbnail(2), for: second, byteCount: 10, modifiedAt: Date(timeIntervalSince1970: 20)))
        try setModified(cache, jpegByte: 2, to: Date(timeIntervalSince1970: 20))
        #expect(store.save(thumbnail(3), for: third, byteCount: 10, modifiedAt: Date(timeIntervalSince1970: 30)))

        #expect(store.cachedThumbnail(for: first, byteCount: 10, modifiedAt: Date(timeIntervalSince1970: 10)) == nil)
        let kept = try #require(store.cachedThumbnail(for: third, byteCount: 10, modifiedAt: Date(timeIntervalSince1970: 30)))
        #expect(kept.jpegData == Data(repeating: 3, count: 300))
        #expect(kept.isSquare == false)
        #expect(try String(contentsOf: keeper, encoding: .utf8) == "keep")
        let names = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        #expect(names.contains { $0.lastPathComponent == "notes.txt" })
        #expect(names.allSatisfy { $0.lastPathComponent == "notes.txt" || $0.pathExtension == "scover" })
    }

    @Test("Nlib uses the base Title ID and only the public icon URL")
    func nlibSelectsBaseTitle() {
        let base = "0100000000010000"
        let update = "0100000000010800"
        let dlc = "0100000000010001"
        let game = Game(id: "/library/Odyssey/update.nsp", title: "Odyssey", contents: [
            LocalContent(id: "/library/Odyssey/update.nsp", titleID: update, kind: .update, fileURL: URL(fileURLWithPath: "/library/Odyssey/update.nsp"), byteCount: 8, format: .nsp),
            LocalContent(id: "/library/Odyssey/base.nsp", titleID: base.lowercased(), kind: .base, fileURL: URL(fileURLWithPath: "/library/Odyssey/base.nsp"), byteCount: 8, format: .nsp)
        ])
        #expect(NlibCoverClient.titleID(for: game) == base)
        #expect(NlibCoverClient.iconURL(for: base)?.absoluteString == "https://api.nlib.cc/nx/\(base)/icon/480")
        #expect(NlibCoverClient.allows(NlibCoverClient.iconURL(for: base)))

        let updateOnly = Game(id: update, title: "Odyssey", contents: [
            LocalContent(id: "/library/Odyssey/update.nsp", titleID: update, kind: .update, fileURL: URL(fileURLWithPath: "/library/Odyssey/update.nsp"), byteCount: 8, format: .nsp)
        ])
        #expect(NlibCoverClient.titleID(for: updateOnly) == base)

        let dlcOnly = Game(id: dlc, title: "Pack", contents: [
            LocalContent(id: "/library/Odyssey/dlc.nsp", titleID: dlc, kind: .dlc, fileURL: URL(fileURLWithPath: "/library/Odyssey/dlc.nsp"), byteCount: 8, format: .nsp)
        ])
        #expect(NlibCoverClient.titleID(for: dlcOnly) == nil)
        #expect(NlibCoverClient.iconURL(for: "screenshot") == nil)
        #expect(NlibCoverClient.allows(URL(string: "http://api.nlib.cc/nx/\(base)/icon/480")) == false)
        #expect(NlibCoverClient.allows(URL(string: "https://example.com/nx/\(base)/icon/480")) == false)
        #expect(NlibCoverClient.allows(URL(string: "https://api.nlib.cc/nx/\(base)/banner/480p")) == false)
    }

    @Test("Nlib download keeps a decoded icon and drops error responses")
    func nlibDownloadDecodesIcon() async throws {
        let png = try pngData(width: 24, height: 24)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NlibURLStub.self]
        let session = URLSession(configuration: configuration)
        let titleID = "0100000000010000"
        let requests = RequestLog()

        NlibURLStub.responder = { request in
            requests.add(request)
            return (200, png)
        }
        let thumbnail = try #require(await NlibCoverClient.thumbnail(for: titleID.lowercased(), session: session))
        #expect(thumbnail.isSquare)
        #expect(max(thumbnail.pixelWidth, thumbnail.pixelHeight) <= CoverImageLoader.maxPixel)
        let seen = requests.all()
        #expect(seen.count == 1)
        #expect(seen[0].value(forHTTPHeaderField: "User-Agent") == NlibCoverClient.userAgent)
        #expect(seen[0].url?.absoluteString == "https://api.nlib.cc/nx/\(titleID)/icon/480")

        NlibURLStub.responder = { _ in (404, Data("missing".utf8)) }
        #expect(await NlibCoverClient.thumbnail(for: titleID, session: session) == nil)

        NlibURLStub.responder = { _ in (200, Data("<html></html>".utf8)) }
        #expect(await NlibCoverClient.thumbnail(for: titleID, session: session) == nil)

        NlibURLStub.responder = { _ in (200, png) }
        #expect(await NlibCoverClient.thumbnail(for: titleID, session: session, maximumByteCount: png.count - 1) == nil)
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    private func setModified(_ directory: URL, jpegByte: UInt8, to date: Date) throws {
        let names = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in names where url.pathExtension == "scover" {
            let data = try Data(contentsOf: url)
            if data.count > 12, data[12] == jpegByte {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                return
            }
        }
        Issue.record("cache file for byte \(jpegByte) was not written")
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    func add(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
    func all() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

private final class NlibURLStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body) = responder(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
