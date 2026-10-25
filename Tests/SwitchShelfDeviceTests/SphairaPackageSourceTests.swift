import Darwin
import Foundation
import Testing
@testable import SwitchShelfDevice

private struct SourceFixture {
    let root: URL
    let file: URL
    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let canonical = try #require(realpath(directory.path, nil))
        defer { free(canonical) }
        root = URL(fileURLWithPath: String(cString: canonical))
        file = root.appendingPathComponent("fixture.nsp")
        try Data(0..<13).write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("sphaira descriptor-pinned sources — local temporary files only")
struct SphairaPackageSourceTests {
    @Test func boundedPositionalReadsAndClose() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        let source = try SphairaPackageSource(url: fixture.file, allowedRoot: fixture.root, expectedBytes: 13)
        #expect(try await source.read(offset: 4, count: 4) == Data([4, 5, 6, 7]))
        #expect(try await source.read(offset: 0, count: 2) == Data([0, 1]))
        for (offset, count): (UInt64, Int) in [(0, 0), (0, -1), (0, 4 * 1024 * 1024 + 1), (13, 1), (.max, 1), (12, 2)] {
            await #expect(throws: SphairaUploadError.self) { try await source.read(offset: offset, count: count) }
        }
        await source.close()
        await #expect(throws: SphairaUploadError.self) { try await source.read(offset: 0, count: 1) }
        await source.close()
        #expect(try Data(contentsOf: fixture.file) == Data(0..<13))
    }

    @Test func allowlistCannotEscapeByPrefixOrParentTraversal() throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        for root in [fixture.root.appendingPathComponent("other"), fixture.root.appendingPathExtension("prefix"), URL(fileURLWithPath: "/")] {
            #expect(throws: SphairaUploadError.self) {
                try SphairaPackageSource(url: fixture.file, allowedRoot: root, expectedBytes: 13)
            }
        }
        #expect(throws: SphairaUploadError.self) {
            try SphairaPackageSource(url: fixture.root.appendingPathComponent("../outside.nsp"),
                allowedRoot: fixture.root, expectedBytes: 13)
        }
        for size: UInt64 in [0, 12, .max] {
            #expect(throws: SphairaUploadError.self) {
                try SphairaPackageSource(url: fixture.file, allowedRoot: fixture.root, expectedBytes: size)
            }
        }
    }

    @Test func symbolicLinksInAnyComponentAreRejected() throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("link.nsp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        #expect(throws: SphairaUploadError.self) {
            try SphairaPackageSource(url: link, allowedRoot: fixture.root, expectedBytes: 13)
        }
        let dirLink = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: fixture.root)
        #expect(throws: SphairaUploadError.self) {
            try SphairaPackageSource(url: dirLink.appendingPathComponent("fixture.nsp"),
                allowedRoot: fixture.root, expectedBytes: 13)
        }
    }

    @Test func replacementsAndInPlaceChangesInvalidateTheSource() async throws {
        for change in ["replace", "truncate", "rewrite", "unlink"] {
            let fixture = try SourceFixture(); defer { fixture.remove() }
            let source = try SphairaPackageSource(url: fixture.file, allowedRoot: fixture.root, expectedBytes: 13)
            switch change {
            case "replace":
                try FileManager.default.moveItem(at: fixture.file, to: fixture.root.appendingPathComponent("old.nsp"))
                try Data(repeating: 5, count: 13).write(to: fixture.file)
            case "truncate": try Data([1]).write(to: fixture.file)
            case "rewrite":
                let file = try FileHandle(forWritingTo: fixture.file)
                try file.write(contentsOf: Data([255])); try file.close()
            default: try FileManager.default.removeItem(at: fixture.file)
            }
            await #expect(throws: SphairaUploadError.sourceChanged) { try await source.validate() }
            await #expect(throws: SphairaUploadError.self) { try await source.read(offset: 0, count: 1) }
            await source.close()
        }
    }

    @Test func directoryAndFIFOAreRejectedWithoutBlocking() throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("dir.nsp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = fixture.root.appendingPathComponent("pipe.nsp")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for url in [directory, fifo] {
            #expect(throws: SphairaUploadError.self) {
                try SphairaPackageSource(url: url, allowedRoot: fixture.root, expectedBytes: 13)
            }
        }
    }

    @Test func parentDirectoryReplacedBySymlinkInvalidatesTheSource() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.nsp")
        try Data(0..<13).write(to: file)
        let source = try SphairaPackageSource(url: file, allowedRoot: fixture.root, expectedBytes: 13)
        let moved = fixture.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        await #expect(throws: SphairaUploadError.sourceChanged) { try await source.validate() }
        await source.close()
    }

    @Test func sparseLargeFileUses64BitOffsetsAndOnlyReadsRequestedBytes() async throws {
        let fixture = try SourceFixture(); defer { fixture.remove() }
        let offset: UInt64 = (1 << 32) + 7
        let file = try FileHandle(forWritingTo: fixture.file)
        try file.seek(toOffset: offset)
        try file.write(contentsOf: Data([4, 3, 2, 1]))
        try file.close()
        let source = try SphairaPackageSource(url: fixture.file, allowedRoot: fixture.root, expectedBytes: offset + 4)
        #expect(try await source.read(offset: offset, count: 4) == Data([4, 3, 2, 1]))
        await source.close()
    }
}
