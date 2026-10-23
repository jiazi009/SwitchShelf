import Foundation
import Testing
@testable import SwitchShelfBackend

@Suite("BackendFileAccess") struct BackendFileAccessTests {
    private func fixture(_ data: Data = Data("abcdef".utf8)) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("source.nsp")
        try data.write(to: url)
        guard let resolved = realpath(url.path, nil) else { throw BackendError.unavailable }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    @Test func exactSliceAndOpaqueID() async throws {
        let url = try fixture()
        let reader = try await AllowlistedBackendFileReader.open(bindings: [.init(id: "not/a/path", url: url, expectedBytes: 6)])
        #expect(try await reader.read(fileID: "not/a/path", offset: 2, length: 3) == Data("cde".utf8))
        await #expect(throws: BackendError.unknownFile) { try await reader.read(fileID: url.path, offset: 0, length: 1) }
    }

    @Test func unknownMissingStaleAndBounds() async throws {
        let url = try fixture()
        await #expect(throws: BackendError.sourceChanged) {
            try await AllowlistedBackendFileReader.open(bindings: [.init(id: "a", url: url, expectedBytes: 7)])
        }
        await #expect(throws: BackendError.sourceChanged) {
            try await AllowlistedBackendFileReader.open(bindings: [.init(id: "a", url: url.deletingLastPathComponent().appendingPathComponent("missing"), expectedBytes: 6)])
        }
        let reader = try await AllowlistedBackendFileReader.open(bindings: [.init(id: "a", url: url, expectedBytes: 6)])
        let ranges: [(UInt64, Int)] = [(7, 1), (6, 1), (UInt64.max, 2), (0, 0), (0, 1_048_577)]
        for (offset, length) in ranges {
            await #expect(throws: BackendError.rangeOutOfBounds) { try await reader.read(fileID: "a", offset: offset, length: length) }
        }
        try Data("changed".utf8).write(to: url)
        await #expect(throws: BackendError.sourceChanged) { try await reader.read(fileID: "a", offset: 0, length: 1) }
    }

    @Test func symlinkAndReplacementRejected() async throws {
        let url = try fixture()
        let link = url.deletingLastPathComponent().appendingPathComponent("link.nsp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        await #expect(throws: BackendError.sourceChanged) {
            try await AllowlistedBackendFileReader.open(bindings: [.init(id: "link", url: link, expectedBytes: 6)])
        }
        let reader = try await AllowlistedBackendFileReader.open(bindings: [.init(id: "a", url: url, expectedBytes: 6)])
        let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.nsp")
        try Data("abcdef".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        await #expect(throws: BackendError.sourceChanged) { try await reader.read(fileID: "a", offset: 0, length: 1) }
    }

    @Test func ancestorSymlinkAndCancellation() async throws {
        let url = try fixture()
        let alias = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: alias) }
        await #expect(throws: BackendError.sourceChanged) {
            try await AllowlistedBackendFileReader.open(bindings: [.init(id: "alias", url: alias.appendingPathComponent("source.nsp"), expectedBytes: 6)])
        }
        let reader = try await AllowlistedBackendFileReader.open(bindings: [.init(id: "a", url: url, expectedBytes: 6)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.read(fileID: "a", offset: 0, length: 2)
        }
        await #expect(throws: BackendError.cancelled) { try await task.value }
    }
}
