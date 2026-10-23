import Foundation
import Testing
@testable import SwitchShelfBackend

@Suite("BackendPreflight") struct BackendPreflightTests {
    private func fixture(_ name: String = "sample.nsp", bytes: Int = 4) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: file)
        return file
    }

    private func entry(_ url: URL?, id: String = "opaque-id", name: String = "sample.nsp", bytes: Int64 = 4, included: Bool = true, online: Bool = true) -> BackendPreflightEntry {
        .init(id: id, name: name, expectedBytes: bytes, included: included, sourceURL: url, sourceAvailable: online, snapshotBytes: bytes)
    }

    private func input(_ entries: [BackendPreflightEntry], target: String = "sd") -> BackendPreflightInput {
        .init(items: [.init(id: "game", intendedTarget: target, entries: entries)])
    }

    @Test func missingMappingNeverGuessesOpaqueID() {
        let result = BackendPreflight.check(input([entry(nil)]))
        #expect(!result.isPrepared)
        #expect(result.offers.isEmpty)
        #expect(result.issues.first?.message.contains("映射") == true)
    }

    @Test func offlineMissingUnreadableAndNonRegular() throws {
        let file = try fixture()
        #expect(!BackendPreflight.check(input([entry(file, online: false)])).isPrepared)
        let missing = file.deletingLastPathComponent().appendingPathComponent("missing.nsp")
        #expect(!BackendPreflight.check(input([entry(missing, name: "missing.nsp")])).isPrepared)
        let directory = file.deletingLastPathComponent().appendingPathComponent("folder.nsp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(!BackendPreflight.check(input([entry(directory, name: "folder.nsp")])).isPrepared)
        let link = file.deletingLastPathComponent().appendingPathComponent("link.nsp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(!BackendPreflight.check(input([entry(link, name: "link.nsp")])).isPrepared)
        let unreadable = file.deletingLastPathComponent().appendingPathComponent("unreadable.nsp")
        try Data(repeating: 1, count: 4).write(to: unreadable)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        #expect(!BackendPreflight.check(input([entry(unreadable, name: "unreadable.nsp")])).isPrepared)
    }

    @Test func changedSizeAndSnapshotEvidence() throws {
        let file = try fixture()
        #expect(BackendPreflight.check(input([entry(file)])).isPrepared)
        #expect(!BackendPreflight.check(input([entry(file, bytes: 5)])).isPrepared)
        let mismatched = BackendPreflightEntry(id: "opaque", name: "sample.nsp", expectedBytes: 4, included: true, sourceURL: file, sourceAvailable: true, snapshotBytes: 5)
        #expect(!BackendPreflight.check(input([mismatched])).isPrepared)
    }

    @Test func excludedContentIgnoredAndDuplicateNamesBlocked() throws {
        let file = try fixture()
        let excluded = entry(nil, id: "missing", name: "bad/name.nsp", included: false)
        let good = BackendPreflight.check(input([excluded, entry(file)]))
        #expect(good.isPrepared)
        #expect(good.offers.map(\.id) == ["opaque-id"])
        let duplicate = entry(file, id: "second")
        #expect(!BackendPreflight.check(input([entry(file), duplicate])).isPrepared)
        #expect(BackendPreflight.check(input([entry(file), duplicate])).issues.contains { $0.message.contains("重复") })
    }

    @Test func listWireBytesAreBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var entries: [BackendPreflightEntry] = []
        for index in 0..<263 {
            let name = String(repeating: "a", count: 242) + String(format: "%04d", index) + ".nsp"
            let file = directory.appendingPathComponent(name)
            try Data().write(to: file)
            entries.append(entry(file, id: "id-\(index)", name: name, bytes: 0))
        }
        let result = BackendPreflight.check(input(entries))
        #expect(!result.isPrepared)
        #expect(result.issues.contains { $0.message.contains("65,536") })
    }

    @Test func namesAndIntentAndInvalidation() throws {
        let file = try fixture()
        for name in ["../sample.nsp", "bad\\sample.nsp", "bad\nsample.nsp", "sample.txt", String(repeating: "中", count: 90) + ".nsp"] {
            #expect(!BackendPreflight.check(input([entry(file, name: name)])).isPrepared)
        }
        let original = input([entry(file)])
        let result = BackendPreflight.check(original)
        #expect(result.isPrepared)
        #expect(result.isCurrent(for: original))
        #expect(!result.isCurrent(for: input([entry(file)], target: "nand")))
        #expect(!result.isCurrent(for: input([entry(file, included: false)])))
        #expect(!result.isCurrent(for: input([entry(file, online: false)])))
        #expect(!result.isCurrent(for: input([entry(nil)])))
        #expect(!result.isCurrent(for: .init(items: [.init(id: "other", intendedTarget: "sd", entries: [entry(file)]), original.items[0]])))
        // Neither SD nor NAND is sent in an offer; changing target invalidates preparation.
        #expect(result.offers == [.init(id: "opaque-id", name: "sample.nsp", byteCount: 4)])
    }
}
