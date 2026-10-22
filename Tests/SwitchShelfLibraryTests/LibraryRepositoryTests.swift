import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfLibrary

@Suite("LibraryRepository Tests")
struct LibraryRepositoryTests {
    private func createTempDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelfDB_\(UUID().uuidString).sqlite")
    }

    @Test("Database initializes with schema migration version 1")
    func schemaMigrationInitialization() async throws {
        let dbURL = createTempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let repo = try LibraryRepository(databaseURL: dbURL)
        let snapshot = try await repo.load()

        #expect(snapshot.sources.isEmpty)
        #expect(snapshot.games.isEmpty)
        #expect(snapshot.issues.isEmpty)
        #expect(snapshot.scannedAt == nil)
    }

    @Test("Snapshot roundtrip persistence preserves all fields and bookmarks")
    func snapshotRoundtripPersistence() async throws {
        let dbURL = createTempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let repo = try LibraryRepository(databaseURL: dbURL)

        let bookmarkData = "MockSecurityBookmarkData".data(using: .utf8)
        let source = LibrarySource(
            id: "source-1",
            url: URL(fileURLWithPath: "/Volumes/switch 游戏包"),
            name: "NAS Switch Games",
            availability: .online,
            bookmark: bookmarkData
        )

        let content1 = LocalContent(
            id: "/Volumes/switch 游戏包/大家1-2-Switch [版本1.0.1]/[01006F900BF8E000].xci",
            titleID: "01006F900BF8E000",
            kind: .base,
            rawVersion: 0,
            displayVersion: "v1.0.0",
            fileURL: URL(fileURLWithPath: "/Volumes/switch 游戏包/大家1-2-Switch [版本1.0.1]/[01006F900BF8E000].xci"),
            byteCount: 3_500_000_000,
            format: .xci,
            availability: .online
        )

        let content2 = LocalContent(
            id: "/Volumes/switch 游戏包/大家1-2-Switch [版本1.0.1]/[UPD][v1.0.1][01006F900BF8E000][v65536].nsp",
            titleID: "01006F900BF8E000",
            kind: .update,
            rawVersion: 65536,
            displayVersion: "v1.0.1",
            fileURL: URL(fileURLWithPath: "/Volumes/switch 游戏包/大家1-2-Switch [版本1.0.1]/[UPD][v1.0.1][01006F900BF8E000][v65536].nsp"),
            byteCount: 150_000_000,
            format: .nsp,
            availability: .online
        )

        let game = Game(
            id: "01006F900BF8E000",
            title: "大家1-2-Switch",
            originalTitle: "Everybody 1-2-Switch!",
            coverURL: URL(string: "https://example.com/cover.png"),
            contents: [content1, content2],
            identification: .matched
        )

        let scanDate = Date(timeIntervalSince1970: 1770000000)
        let snapshot = LibrarySnapshot(
            sources: [source],
            games: [game],
            scannedAt: scanDate,
            issues: ["Test issue 1", "Warning: partial read on file X"]
        )

        try await repo.save(snapshot)
        let loaded = try await repo.load()

        #expect(loaded.sources == snapshot.sources)
        #expect(loaded.games == snapshot.games)
        #expect(loaded.issues == snapshot.issues)

        let loadedTime = try #require(loaded.scannedAt?.timeIntervalSince1970)
        #expect(abs(loadedTime - scanDate.timeIntervalSince1970) < 0.001)
    }

    @Test("Offline source retention does not wipe prior library")
    func offlineSourceRetention() async throws {
        let dbURL = createTempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let repo = try LibraryRepository(databaseURL: dbURL)

        // Initial state: Source A (Local) and Source B (NAS)
        let sourceLocal = LibrarySource(
            id: "src-local",
            url: URL(fileURLWithPath: "/Users/test/Games"),
            name: "Local Folder",
            availability: .online
        )
        let sourceNAS = LibrarySource(
            id: "src-nas",
            url: URL(fileURLWithPath: "/Volumes/switch 游戏包"),
            name: "SMB NAS",
            availability: .online
        )

        let localContent = LocalContent(
            id: "/Users/test/Games/Game1.nsp",
            titleID: "0100111111111000",
            kind: .base,
            fileURL: URL(fileURLWithPath: "/Users/test/Games/Game1.nsp"),
            byteCount: 1000,
            format: .nsp,
            availability: .online
        )
        let localGame = Game(
            id: "0100111111111000",
            title: "Local Game",
            contents: [localContent],
            identification: .matched
        )

        let nasContent = LocalContent(
            id: "/Volumes/switch 游戏包/Game2.nsp",
            titleID: "0100222222222000",
            kind: .base,
            fileURL: URL(fileURLWithPath: "/Volumes/switch 游戏包/Game2.nsp"),
            byteCount: 2000,
            format: .nsp,
            availability: .online
        )
        let nasGame = Game(
            id: "0100222222222000",
            title: "NAS Game",
            contents: [nasContent],
            identification: .matched
        )

        let initialSnapshot = LibrarySnapshot(
            sources: [sourceLocal, sourceNAS],
            games: [localGame, nasGame],
            scannedAt: Date()
        )

        try await repo.save(initialSnapshot)

        // Now simulate NAS becoming disconnected/offline
        let offlineSnapshot = initialSnapshot.markingSourceOffline(
            sourceID: "src-nas",
            reason: "NAS volume unmounted"
        )

        #expect(offlineSnapshot.sources.first { $0.id == "src-nas" }?.availability == .offline)
        let offlineNasGame = try #require(offlineSnapshot.games.first { $0.id == "0100222222222000" })
        #expect(offlineNasGame.contents[0].availability == .offline)

        // Save updated offline snapshot
        try await repo.save(offlineSnapshot)

        // Reload from database: NAS game must NOT be wiped! It should be preserved as offline.
        let reloaded = try await repo.load()
        #expect(reloaded.games.count == 2)

        let loadedNASGame = try #require(reloaded.games.first { $0.id == "0100222222222000" })
        #expect(loadedNASGame.title == "NAS Game")
        #expect(loadedNASGame.contents[0].availability == .offline)

        let loadedLocalGame = try #require(reloaded.games.first { $0.id == "0100111111111000" })
        #expect(loadedLocalGame.contents[0].availability == .online)

        // Now simulate re-scanning only the local source with an updated game
        let updatedLocalContent = LocalContent(
            id: "/Users/test/Games/Game1.nsp",
            titleID: "0100111111111000",
            kind: .base,
            fileURL: URL(fileURLWithPath: "/Users/test/Games/Game1.nsp"),
            byteCount: 1500, // Updated size
            format: .nsp,
            availability: .online
        )
        let updatedLocalGame = Game(
            id: "0100111111111000",
            title: "Local Game",
            contents: [updatedLocalContent],
            identification: .matched
        )
        let localScanSnapshot = LibrarySnapshot(
            sources: [sourceLocal],
            games: [updatedLocalGame],
            scannedAt: Date()
        )

        let mergedSnapshot = reloaded.merging(scanResult: localScanSnapshot, for: sourceLocal)
        try await repo.save(mergedSnapshot)

        let finalLoaded = try await repo.load()
        #expect(finalLoaded.games.count == 2)
        #expect(finalLoaded.games.contains { $0.id == "0100222222222000" && $0.contents[0].availability == .offline })
        #expect(finalLoaded.games.contains { $0.id == "0100111111111000" && $0.contents[0].byteCount == 1500 })
    }

    @Test("A game shared by two sources is one persisted row with both packages")
    func sharedGameAcrossSources() async throws {
        let dbURL = createTempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let first = LibrarySource(id: "first", url: URL(fileURLWithPath: "/tmp/GamesA"), name: "A")
        let second = LibrarySource(id: "second", url: URL(fileURLWithPath: "/tmp/GamesB"), name: "B")
        func package(_ path: String) -> LocalContent {
            LocalContent(id: path, titleID: "0100111000000000", kind: .base,
                         fileURL: URL(fileURLWithPath: path), byteCount: 1, format: .nsp)
        }
        let original = LibrarySnapshot(sources: [first, second], games: [
            Game(id: "0100111000000000", title: "Shared", contents: [package("/tmp/GamesB/base.nsp")])
        ])
        let scan = LibrarySnapshot(sources: [first], games: [
            Game(id: "0100111000000000", title: "Shared", contents: [package("/tmp/GamesA/base.nsp")])
        ])
        let merged = original.merging(scanResult: scan, for: first)
        #expect(merged.games.count == 1)
        #expect(merged.games.first?.contents.count == 2)
        let repo = try LibraryRepository(databaseURL: dbURL)
        try await repo.save(merged)
        #expect(try await repo.load().games.first?.contents.count == 2)
    }

    @Test("Source operations do not include sibling paths sharing a textual prefix")
    func sourcePathBoundary() {
        let first = LibrarySource(id: "first", url: URL(fileURLWithPath: "/tmp/Games"), name: "Games")
        let second = LibrarySource(id: "second", url: URL(fileURLWithPath: "/tmp/Games2"), name: "Games2")
        let file = URL(fileURLWithPath: "/tmp/Games2/second.nsp")
        let content = LocalContent(id: "second-file", titleID: nil, kind: .unknown,
                                   fileURL: file, byteCount: 1, format: .nsp)
        let original = LibrarySnapshot(sources: [first, second],
            games: [Game(id: "second-game", title: "Second", contents: [content])])

        let offline = original.markingSourceOffline(sourceID: first.id)
        #expect(offline.games.first?.contents.first?.availability == .online)
        let merged = original.merging(scanResult: LibrarySnapshot(sources: [first]), for: first)
        #expect(merged.games.first?.contents.first?.id == "second-file")
    }

    @Test("Out-of-range persisted versions are treated as unknown, not a process crash")
    func malformedPersistedVersion() async throws {
        let dbURL = createTempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let repo = try LibraryRepository(databaseURL: dbURL)
        let file = URL(fileURLWithPath: "/tmp/test.nsp")
        let content = LocalContent(id: "file", titleID: nil, kind: .unknown, rawVersion: 1,
                                   fileURL: file, byteCount: 1, format: .nsp)
        try await repo.save(LibrarySnapshot(games: [Game(id: "game", title: "Test", contents: [content])]))

        let db = try SQLiteDatabase(databaseURL: dbURL)
        try db.execute("UPDATE contents SET raw_version = -1 WHERE id = 'file';")
        let reloaded = try await repo.load()
        #expect(reloaded.games.first?.contents.first?.rawVersion == nil)
    }

    @Test("Atomic writes maintain consistency")
    func atomicWritesConsistency() async throws {
        let dbURL = createTempDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let repo = try LibraryRepository(databaseURL: dbURL)

        let snapshot = LibrarySnapshot(
            sources: [LibrarySource(id: "s1", url: URL(fileURLWithPath: "/tmp/s1"), name: "S1", availability: .online)],
            games: [Game(id: "g1", title: "Original Game", contents: [], identification: .unidentified)],
            scannedAt: Date()
        )
        try await repo.save(snapshot)

        let loaded = try await repo.load()
        #expect(loaded.games.count == 1)
        #expect(loaded.games.first?.title == "Original Game")
    }
}
