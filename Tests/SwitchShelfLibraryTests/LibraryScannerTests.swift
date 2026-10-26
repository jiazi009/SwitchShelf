import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfLibrary

@Suite("LibraryScanner Tests")
struct LibraryScannerTests {
    private func createTempDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelfTest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func createDummyFile(at url: URL, size: Int = 1024) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dummyData = Data(repeating: 0xAB, count: size)
        try dummyData.write(to: url)
    }

    @Test("Scan recurses through nested subdirectories")
    func scanRecursion() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Create nested game directory structure:
        // root/SuperGame/base/SuperGame [0100111000000000][v0].nsp
        // root/SuperGame/upd/SuperGame [0100111000000800][v65536].nsp
        // root/SuperGame/dlc/SuperGame [0100111000001001][v0][DLC].nsp
        let baseFile = root.appendingPathComponent("SuperGame/base/SuperGame [0100111000000000][v0].nsp")
        let updFile = root.appendingPathComponent("SuperGame/upd/SuperGame [0100111000000800][v65536].nsp")
        let dlcFile = root.appendingPathComponent("SuperGame/dlc/SuperGame [0100111000001001][v0][DLC].nsp")

        try createDummyFile(at: baseFile, size: 2048)
        try createDummyFile(at: updFile, size: 1024)
        try createDummyFile(at: dlcFile, size: 512)

        let scanner = LibraryScanner()
        let source = LibrarySource(url: root, name: "Test Source")
        let snapshot = try await scanner.scan(source)

        #expect(snapshot.sources.count == 1)
        #expect(snapshot.sources[0].availability == .online)
        #expect(snapshot.games.count == 1)

        let game = try #require(snapshot.games.first)
        #expect(game.title == "SuperGame")
        #expect(game.contents.count == 3)
        #expect(game.identification == .matched)
        // Ensure never verified!
        #expect(game.identification != .verified)

        let kinds = game.contents.map(\.kind)
        #expect(kinds.contains(.base))
        #expect(kinds.contains(.update))
        #expect(kinds.contains(.dlc))
    }

    @Test("Scan avoids following symlinks")
    func scanAvoidsSymlinks() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let externalDir = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: externalDir) }

        // Normal game in root
        let regularGame = root.appendingPathComponent("GameA/[0100AAAA00000000][v0].xci")
        try createDummyFile(at: regularGame)

        // Game in external directory
        let externalGame = externalDir.appendingPathComponent("ExternalGame/[0100BBBB00000000][v0].xci")
        try createDummyFile(at: externalGame)

        // Symlink pointing to external directory
        let symlinkDir = root.appendingPathComponent("SymlinkedDir")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: externalDir)

        // Symlink pointing to external file
        let symlinkFile = root.appendingPathComponent("SymlinkedFile.xci")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: externalGame)

        let scanner = LibraryScanner()
        let source = LibrarySource(url: root, name: "Symlink Test")
        let snapshot = try await scanner.scan(source)

        // Only GameA should be scanned. ExternalGame must NOT be discovered through symlinks!
        #expect(snapshot.games.count == 1)
        #expect(snapshot.games.first?.id == "0100AAAA00000000")
    }

    @Test("Scan ignores AppleDouble and temporary files")
    func scanIgnoresAppleDoubleAndTemporaryFiles() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let validGame = root.appendingPathComponent("Game/[0100123456789000][v0].nsp")
        let appleDouble = root.appendingPathComponent("Game/._[0100123456789000][v0].nsp")
        let partFile = root.appendingPathComponent("Game/DownloadingGame.nsp.part")
        let tmpFile = root.appendingPathComponent("Game/temp_transfer.tmp")
        let hiddenFile = root.appendingPathComponent("Game/.DS_Store")

        try createDummyFile(at: validGame)
        try createDummyFile(at: appleDouble)
        try createDummyFile(at: partFile)
        try createDummyFile(at: tmpFile)
        try createDummyFile(at: hiddenFile)

        let scanner = LibraryScanner()
        let source = LibrarySource(url: root, name: "Temp Filter Test")
        let snapshot = try await scanner.scan(source)

        #expect(snapshot.games.count == 1)
        #expect(snapshot.games[0].contents.count == 1)
        #expect(snapshot.games[0].contents[0].fileURL.lastPathComponent == "[0100123456789000][v0].nsp")
    }

    @Test("Scan supports Chinese filenames and spaces")
    func scanChineseFilenamesAndSpaces() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let zelda = root.appendingPathComponent("塞尔达传说 旷野之息/塞尔达传说 旷野之息 [01007EF00011E000][v0].xci")
        let switch12 = root.appendingPathComponent("大家1-2-Switch [版本1.0.1]/[01006F900BF8E000].xci")
        let switch12Upd = root.appendingPathComponent("大家1-2-Switch [版本1.0.1]/[UPD][v1.0.1][01006F900BF8E000][v65536].nsp")

        try createDummyFile(at: zelda, size: 4096)
        try createDummyFile(at: switch12, size: 2048)
        try createDummyFile(at: switch12Upd, size: 1024)

        let scanner = LibraryScanner()
        let source = LibrarySource(url: root, name: "Chinese Test")
        let snapshot = try await scanner.scan(source)

        #expect(snapshot.games.count == 2)
        let titles = snapshot.games.map(\.title)
        #expect(titles.contains("塞尔达传说 旷野之息"))
        #expect(titles.contains("大家1-2-Switch"))

        let switchGame = try #require(snapshot.games.first { $0.title == "大家1-2-Switch" })
        #expect(switchGame.contents.count == 2)
        #expect(switchGame.byteCount == 3072)
    }

    @Test("Scan preserves unknown IDs and meaningful display names")
    func scanUnknownIDs() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let homebrew1 = root.appendingPathComponent("HomebrewApp.nsp")
        let homebrew2 = root.appendingPathComponent("Custom Utilities/SuperTool.xci")

        try createDummyFile(at: homebrew1)
        try createDummyFile(at: homebrew2)

        let scanner = LibraryScanner()
        let source = LibrarySource(url: root, name: "Unknown Test")
        let snapshot = try await scanner.scan(source)

        #expect(snapshot.games.count == 2)
        let titles = snapshot.games.map(\.title)
        #expect(titles.contains("HomebrewApp"))
        #expect(titles.contains("SuperTool"))

        for game in snapshot.games {
            #expect(game.identification == .unidentified)
            #expect(game.identification != .verified)
        }
    }

    @Test("Grouping groups base/update/DLC reliably and does not force DLC arithmetic")
    func scanReliableGrouping() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Game 1 in Game1 folder
        let g1Base = root.appendingPathComponent("LuigiMansion/nsz本体/[0100DCA0064A6000][US][v0][BASE].nsz")
        let g1Upd = root.appendingPathComponent("LuigiMansion/upd-v1.4.0/[UPD][v1.4.0][0100DCA0064A6800][US][v327680].nsz")
        let g1Dlc = root.appendingPathComponent("LuigiMansion/dlc-2/[DLC][0100DCA0064A7001][US][v131072].nsz")

        // Standalone loose DLC in an unrelated standalone folder with NO base game
        let looseDlc = root.appendingPathComponent("StandaloneLooseFolder/[DLC][0100999000001001][US][v0].nsz")

        try createDummyFile(at: g1Base)
        try createDummyFile(at: g1Upd)
        try createDummyFile(at: g1Dlc)
        try createDummyFile(at: looseDlc)

        let scanner = LibraryScanner()
        let source = LibrarySource(url: root, name: "Grouping Test")
        let snapshot = try await scanner.scan(source)

        // LuigiMansion should have base + update + dlc
        // Loose DLC should NOT be forced into LuigiMansion! It forms its own game entry.
        #expect(snapshot.games.count == 2)

        let luigi = try #require(snapshot.games.first { $0.id == "0100DCA0064A6000" })
        #expect(luigi.contents.count == 3)
        #expect(luigi.identification == .matched)
        #expect(luigi.identification != .verified)

        let looseGame = try #require(snapshot.games.first { $0.id != "0100DCA0064A6000" })
        #expect(looseGame.contents.count == 1)
        #expect(looseGame.contents[0].kind == .dlc)
    }

    @Test("Filename Title ID can match a current base without becoming verified")
    func filenameTitleIDMatchesInstalledBaseWithoutVerification() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDummyFile(at: root.appendingPathComponent("Game [0100111000000000][v0].nsp"))
        let snapshot = try await LibraryScanner().scan(LibrarySource(url: root, name: "Candidate"))
        let game = try #require(snapshot.games.first)
        #expect(game.identification == .matched)
        #expect(game.identification != .verified)
        let inventory = InstalledInventory(deviceID: "fixture-session", isComplete: true,
            records: [InstalledRecord(id: "fixture", titleID: "0100111000000000", kind: .base,
                                      name: "Game", objectPath: "/Installed games/Game")])
        let assessment = InstallationAssessor.assess(game, inventory: inventory, isCurrentSession: true)
        #expect(assessment.state == .installed)
        #expect(assessment.explanation.contains("文件名"))
        #expect(assessment.explanation.contains("未验证"))
        #expect(game.identification == .matched)
    }

    @Test("A matching display title alone never attaches an unidentified update")
    func sameTitleIsNotContentRelation() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDummyFile(at: root.appendingPathComponent("Same [0100111000000000][v0].nsp"))
        try createDummyFile(at: root.appendingPathComponent("Same [UPD][v65536].nsp"))

        let snapshot = try await LibraryScanner().scan(LibrarySource(url: root, name: "Collision"))
        #expect(snapshot.games.count == 2)
        #expect(snapshot.games.first { $0.id == "0100111000000000" }?.contents.count == 1)
        #expect(snapshot.games.first { $0.contents.first?.kind == .update }?.contents.count == 1)
    }

    @Test("One folder containing multiple bases cannot assign DLC to an arbitrary base")
    func ambiguousFolderDoesNotAssignDLC() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try createDummyFile(at: root.appendingPathComponent("Collection/One [0100111000000000][BASE].nsp"))
        try createDummyFile(at: root.appendingPathComponent("Collection/Two [0100222000000000][BASE].nsp"))
        try createDummyFile(at: root.appendingPathComponent("Collection/Bonus [0100333000001001][DLC].nsp"))

        let snapshot = try await LibraryScanner().scan(LibrarySource(url: root, name: "Ambiguous"))
        #expect(snapshot.games.count == 3)
        #expect(snapshot.games.first { $0.id == "0100111000000000" }?.contents.count == 1)
        #expect(snapshot.games.first { $0.id == "0100222000000000" }?.contents.count == 1)
        #expect(snapshot.games.first { $0.contents.first?.kind == .dlc }?.contents.count == 1)
    }

    @Test("Partial scan failures capture issues without failing entire scan")
    func scanPartialFailures() async throws {
        let root = try createTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Good game
        let goodGame = root.appendingPathComponent("GoodFolder/GoodGame [0100555000000000][v0].nsp")
        try createDummyFile(at: goodGame)

        // Unreadable folder
        let unreadableFolder = root.appendingPathComponent("UnreadableFolder")
        try FileManager.default.createDirectory(at: unreadableFolder, withIntermediateDirectories: true)
        let unreadableGame = unreadableFolder.appendingPathComponent("Secret [0100666000000000][v0].nsp")
        try createDummyFile(at: unreadableGame)

        // Make folder unreadable
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableFolder.path)
        defer {
            // Restore permissions for cleanup
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableFolder.path)
        }

        let scanner = LibraryScanner()
        let source = LibrarySource(url: root, name: "Partial Failure Test")
        let snapshot = try await scanner.scan(source)

        // GoodGame must still be scanned and returned!
        #expect(snapshot.games.count >= 1)
        #expect(snapshot.games.contains { $0.title == "GoodGame" })
        // Issues should record the unreadable folder error
        #expect(!snapshot.issues.isEmpty)
    }

    @Test("Source unavailable throws LibraryScanError")
    func scanSourceUnavailable() async throws {
        let nonExistentURL = URL(fileURLWithPath: "/non/existent/directory_\(UUID().uuidString)")
        let scanner = LibraryScanner()
        let source = LibrarySource(url: nonExistentURL, name: "Missing Source")

        await #expect(throws: LibraryScanError.self) {
            _ = try await scanner.scan(source)
        }
    }
}
