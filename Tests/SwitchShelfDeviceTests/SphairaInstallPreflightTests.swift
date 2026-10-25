import Darwin
import Foundation
import Testing
@testable import SwitchShelfDevice

private struct PackageFixture {
    let directory: URL
    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let canonical = try #require(realpath(temporary.path, nil))
        defer { free(canonical) }
        directory = URL(fileURLWithPath: String(cString: canonical))
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func entry(name: String = "fixture.nsp", id: String = "file", size: Int64 = 3,
               included: Bool = true, online: Bool = true, snapshotSize: Int64? = 3) throws -> SphairaPreflightEntry {
        let url = directory.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: url)
        return .init(id: id, name: name, expectedBytes: size, included: included,
                     sourceURL: url, sourceAvailable: online, snapshotBytes: snapshotSize)
    }
}

private func input(_ entries: [SphairaPreflightEntry], target: String = "sd") -> SphairaPreflightInput {
    .init(items: [.init(id: "plan", intendedTarget: target, entries: entries)])
}

@Suite("sphaira MTP metadata-only preparation")
struct SphairaInstallPreflightTests {
    @Test func ordinaryPackageAndSnapshotFreshness() throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        let entry = try fixture.entry()
        let checked = SphairaInstallPreflight.check(input([entry]))
        #expect(checked.isPrepared)
        #expect(checked.offers.first?.byteCount == 3)
        #expect(checked.isCurrent(for: input([entry])))
        #expect(!checked.isCurrent(for: input([entry], target: "nand")))
        #expect(!checked.isCurrent(for: input([])))
    }

    @Test(arguments: ["nsp", "XCI", "nsz", "xcz", "msp"])
    func documentedExtensions(_ ext: String) throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        #expect(SphairaInstallPreflight.check(input([try fixture.entry(name: "fixture.\(ext)")])).isPrepared)
    }

    @Test func emptyAndExcludedPlansDoNotPrepare() throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        #expect(!SphairaInstallPreflight.check(input([])).isPrepared)
        #expect(!SphairaInstallPreflight.check(input([try fixture.entry(included: false)])).isPrepared)
    }

    @Test func zeroNegativeAndStaleSizesFail() throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        for size: Int64 in [0, -1, 4] {
            #expect(!SphairaInstallPreflight.check(input([try fixture.entry(size: size)])).isPrepared)
        }
        #expect(!SphairaInstallPreflight.check(input([try fixture.entry(snapshotSize: 4)])).isPrepared)
    }

    @Test func missingOfflineOrMismatchedMappingFails() throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        #expect(!SphairaInstallPreflight.check(input([try fixture.entry(online: false)])).isPrepared)
        let entry = try fixture.entry()
        try FileManager.default.removeItem(at: entry.sourceURL!)
        #expect(!SphairaInstallPreflight.check(input([entry])).isPrepared)
        for url in [nil, URL(string: "https://example.invalid/fixture.nsp"), fixture.directory.appendingPathComponent("other.nsp")] {
            let bad = SphairaPreflightEntry(id: "file", name: "fixture.nsp", expectedBytes: 3,
                included: true, sourceURL: url, sourceAvailable: true)
            #expect(!SphairaInstallPreflight.check(input([bad])).isPrepared)
        }
    }

    @Test func duplicateIDsAndCaseFoldedNamesFailAcrossPlans() throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        let first = try fixture.entry()
        let duplicateID = try fixture.entry(name: "second.nsp")
        #expect(!SphairaInstallPreflight.check(input([first, duplicateID])).isPrepared)
        let sameName = SphairaPreflightEntry(id: "second", name: "FIXTURE.NSP", expectedBytes: 3,
            included: true, sourceURL: first.sourceURL, sourceAvailable: true)
        let plans = SphairaPreflightInput(items: [
            .init(id: "one", intendedTarget: "sd", entries: [first]),
            .init(id: "two", intendedTarget: "sd", entries: [sameName])
        ])
        let result = SphairaInstallPreflight.check(plans)
        #expect(!result.isPrepared)
        #expect(result.issues.contains { $0.message.contains("安装文件名重复") })
        #expect(SphairaPackageName.collisionKey("é.nsp") == SphairaPackageName.collisionKey("e\u{301}.NSP"))
    }

    @Test func symlinkFileAndDirectoryAreRejected() throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        let entry = try fixture.entry()
        let alias = fixture.directory.appendingPathComponent("alias.nsp")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: entry.sourceURL!)
        let link = SphairaPreflightEntry(id: "link", name: "alias.nsp", expectedBytes: 3,
            included: true, sourceURL: alias, sourceAvailable: true)
        #expect(!SphairaInstallPreflight.check(input([link])).isPrepared)
        let directoryLink = fixture.directory.appendingPathComponent("linked")
        let actual = fixture.directory.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: actual.appendingPathComponent("fixture.nsp"))
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: actual)
        let nested = SphairaPreflightEntry(id: "nested", name: "fixture.nsp", expectedBytes: 3,
            included: true, sourceURL: directoryLink.appendingPathComponent("fixture.nsp"), sourceAvailable: true)
        #expect(!SphairaInstallPreflight.check(input([nested])).isPrepared)
    }

    @Test func directoriesAreNotPackages() throws {
        let fixture = try PackageFixture(); defer { fixture.remove() }
        let url = fixture.directory.appendingPathComponent("folder.nsp")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let entry = SphairaPreflightEntry(id: "folder", name: "folder.nsp", expectedBytes: 3,
            included: true, sourceURL: url, sourceAvailable: true)
        #expect(!SphairaInstallPreflight.check(input([entry])).isPrepared)
    }

    @Test func filenameBoundsAndPathCharacters() {
        for name in ["", "../file.nsp", "dir\\file.nsp", "a:b.nsp", "a\n.nsp", "a\0.nsp", "a.txt",
                     String(repeating: "a", count: 251) + ".nsp", String(repeating: "游", count: 85) + ".nsp"] {
            #expect(!SphairaPackageName.isValid(name))
        }
        #expect(SphairaPackageName.isValid(String(repeating: "a", count: 250) + ".nsp"))
        #expect(SphairaPackageName.isValid("游戏 🎮.nsp"))
    }
}
