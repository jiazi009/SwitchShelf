import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfLibrary

@Suite("Legacy cache migration")
struct LibraryCacheMigrationTests {
    @Test("Valid prototype JSON is preserved as a backup and imported to SQLite")
    func importsLegacyJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelf-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        let source = LibrarySource(id: "nas", url: URL(fileURLWithPath: "/Volumes/switch 游戏包"), name: "NAS")
        let expected = LibrarySnapshot(sources: [source], scannedAt: Date(timeIntervalSinceReferenceDate: 123))
        try JSONEncoder().encode(expected).write(to: url)

        let migrated = try LibraryCacheMigration.moveLegacyJSONAside(at: url)
        let recovered = try #require(migrated)
        #expect(recovered == expected)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(backups.count == 1)
        #expect(backups[0].hasPrefix("library.sqlite.legacy-json-"))
        let preserved = try Data(contentsOf: directory.appendingPathComponent(backups[0]))
        #expect(try JSONDecoder().decode(LibrarySnapshot.self, from: preserved) == expected)

        let repo = try LibraryRepository(databaseURL: url)
        try await repo.save(recovered)
        #expect(try await repo.load().sources == [source])
    }

    @Test("SQLite and unknown data are never moved or overwritten")
    func doesNotTouchUnrecognizedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelf-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        _ = try LibraryRepository(databaseURL: url)
        #expect(try LibraryCacheMigration.moveLegacyJSONAside(at: url) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains("library.sqlite"))

        try FileManager.default.removeItem(at: url)
        let unknown = Data("not a recognized snapshot".utf8)
        try unknown.write(to: url)
        #expect(throws: LegacyCacheError.self) {
            _ = try LibraryCacheMigration.moveLegacyJSONAside(at: url)
        }
        #expect(try Data(contentsOf: url) == unknown)
    }
}
