import Darwin
import Foundation
import Testing
@testable import SwitchShelfDevice

private struct FileFixture {
    let directory: URL
    let source: URL
    init(bytes: Data = Data("ordinary-file".utf8), name: String = "example.txt") throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let resolved = try #require(realpath(temporary.path, nil))
        defer { free(resolved) }
        directory = URL(fileURLWithPath: String(cString: resolved))
        source = directory.appendingPathComponent(name)
        try bytes.write(to: source)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
private actor FileTransportFixture: MTPFileTransport {
    var stores: [MTPFileStoreRecord]
    var objects: [UInt32: MTPFileObjectRecord]
    var childrenByParent: [UInt32: [UInt32]]
    var requestedParents: [UInt32] = []
    var opened = false
    var closed = false
    var uploadCalls = 0
    var downloadCalls = 0
    var uploaded = Data()
    var downloadBytes: Data
    var failUpload = false
    var failDownload = false
    var failClose = false
    init(name: String = "microSD card", writable: Bool = true,
         objects: [MTPFileObjectRecord] = [], children: [UInt32: [UInt32]] = [.max: []],
         downloadBytes: Data = Data("remote".utf8), failUpload: Bool = false,
         failDownload: Bool = false, failClose: Bool = false) {
        stores = [.init(handle: 9, value: .init(name: name, canUpload: writable, isReadOnly: !writable))]
        self.objects = Dictionary(uniqueKeysWithValues: objects.map { ($0.handle, $0) })
        childrenByParent = children; self.downloadBytes = downloadBytes
        self.failUpload = failUpload; self.failDownload = failDownload; self.failClose = failClose
    }
    func open() { opened = true }
    func storages() -> [MTPFileStoreRecord] { stores }
    func children(storage: UInt32, parent: UInt32) -> [UInt32] {
        requestedParents.append(parent)
        return childrenByParent[parent] ?? []
    }
    func object(_ handle: UInt32) throws -> MTPFileObjectRecord {
        guard let object = objects[handle] else { throw MTPFileError.invalidMetadata }
        return object
    }
    func download(_ handle: UInt32, expectedBytes: UInt64,
                  consume: @escaping @Sendable (Data) async throws -> Void) async throws -> UInt64 {
        downloadCalls += 1
        try await consume(downloadBytes)
        if failDownload { throw MTPFileError.incompleteTransfer }
        return UInt64(downloadBytes.count)
    }
    func upload(storage: UInt32, parent: UInt32, name: String, byteCount: UInt64,
                source: @escaping @Sendable (UInt64, Int) async throws -> Data,
                progress: @escaping @Sendable (UInt64) async -> Void) async throws -> UInt64 {
        uploadCalls += 1
        if failUpload { throw MTPFileError.invalidResponse }
        uploaded = try await source(0, Int(byteCount))
        await progress(byteCount)
        return byteCount
    }
    func close() throws { closed = true; if failClose { throw MTPFileError.invalidResponse } }
}
private actor FileOperationCounts {
    var factories = 0
    var verifies = 0
    var artifact: MTPFilePartialFile?
    func factory() { factories += 1 }
    func verify(failOn: Int? = nil) throws {
        verifies += 1
        if verifies == failOn { throw MTPFileError.changedEntry }
    }
    func partial(_ value: MTPFilePartialFile) { artifact = value }
}
private func fileObject(_ id: UInt32, name: String, parent: UInt32 = 0, storage: UInt32 = 9,
                        folder: Bool = false, size: UInt64? = 6) -> MTPFileObjectRecord {
    .init(handle: id, storage: storage, parent: parent, name: name,
          isDirectory: folder, byteCount: size, modifiedDate: nil)
}
private let sd = MTPFileLocation(storageName: "microSD card")

@Suite("MTP file manager core — fakes and local temporary files only")
struct MTPFileServiceTests {
    @Test func storageListingAndSingleFolderDoNotRecursivelyScan() async throws {
        let transport = FileTransportFixture(objects: [fileObject(1, name: "Folder", folder: true), fileObject(2, name: "child.txt", parent: 1)],
                                             children: [.max: [1], 1: [2], 2: [999]])
        let location = MTPFileLocation(storageName: "microSD card", components: ["Folder"])
        let result = await MTPFileWorker.execute(.list(location: location)) { transport }
        #expect(result.outcome == .completed)
        #expect(result.listing?.entries.map(\.name) == ["child.txt"])
        #expect(await transport.requestedParents == [.max, 1])
        #expect(await transport.closed)
    }
    @Test func pathIsResolvedAgainWithFreshSessionHandles() async throws {
        let location = MTPFileLocation(storageName: "microSD card", components: ["Folder"])
        for id: UInt32 in [1, 900] {
            let transport = FileTransportFixture(objects: [fileObject(id, name: "Folder", folder: true)], children: [.max: [id], id: []])
            let result = await MTPFileWorker.execute(.list(location: location)) { transport }
            #expect(result.outcome == .completed)
            #expect(await transport.requestedParents == [.max, id])
        }
    }
    @Test func gamesVirtualStorageAliasIsAcceptedOnlyWithinGames() async throws {
        for name in ["Games", "microSD card"] {
            let transport = FileTransportFixture(name: name, objects: [fileObject(1, name: "Observed", parent: 9, storage: .max - 1, folder: true)], children: [.max: [1]])
            let result = await MTPFileWorker.execute(.list(location: .init(storageName: name))) { transport }
            #expect(result.outcome == (name == "Games" ? .completed : .failed))
            #expect(await transport.closed)
        }
    }
    @Test func duplicateNormalizedDirectoryNamesCannotSelectAParent() async throws {
        let transport = FileTransportFixture(objects: [fileObject(1, name: "Folder", folder: true), fileObject(2, name: "FOLDER", folder: true)], children: [.max: [1, 2]])
        let result = await MTPFileWorker.execute(.list(location: .init(storageName: "microSD card", components: ["folder"]))) { transport }
        #expect(result.outcome == .failed)
        #expect(await transport.requestedParents == [.max])
    }
    @Test func uploadCollisionUsesCaseFoldingAndUnicodeCanonicalEquivalence() async throws {
        for pair in [("HELLO.txt", "hello.TXT"), ("café.txt", "cafe\u{301}.txt")] {
            let fixture = try FileFixture(name: pair.0); defer { fixture.remove() }
            let request = try MTPFileRequest.upload(sourceURL: fixture.source, to: sd)
            let transport = FileTransportFixture(objects: [fileObject(1, name: pair.1)], children: [.max: [1]])
            let result = await MTPFileWorker.execute(request) { transport }
            #expect(result.outcome == .failed)
            #expect(await transport.uploadCalls == 0)
            #expect(result.message.contains("同名"))
        }
    }
    @Test func uploadsOnlyWritableSDAndNeverVirtualInstallEntrypoints() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        for name in ["Install", "Games", "Contents", "Mounts", "DevNull", "SD Card", "microSD card"] {
            let counts = FileOperationCounts()
            let request = try MTPFileRequest.upload(sourceURL: fixture.source, to: .init(storageName: name))
            let transport = FileTransportFixture(name: name, writable: false)
            let result = await MTPFileWorker.execute(request) { await counts.factory(); return transport }
            #expect(result.outcome == .failed)
            #expect(await transport.uploadCalls == 0)
            if name != "microSD card" { #expect(await counts.factories == 0) }
        }
    }
    @Test func packageNamesAndProtectedNASAreRejectedBeforeSourceRead() throws {
        for suffix in ["nsp", "XCI", "nsz", "xcz"] {
            let fixture = try FileFixture(name: "package." + suffix); defer { fixture.remove() }
            #expect(throws: MTPFileError.uploadNotAllowed) { try MTPFileRequest.upload(sourceURL: fixture.source, to: sd) }
        }
        #expect(throws: MTPFileError.localAccess) {
            try MTPFileUploadSource.review(URL(fileURLWithPath: "/Volumes/switch 游戏包/do-not-open.txt"))
        }
    }
    @Test func uploadReadsPinnedSourceAndSupportsEmptyOrdinaryFiles() async throws {
        for bytes in [Data(), Data("ordinary-data".utf8)] {
            let fixture = try FileFixture(bytes: bytes); defer { fixture.remove() }
            let request = try MTPFileRequest.upload(sourceURL: fixture.source, to: sd)
            let transport = FileTransportFixture()
            let result = await MTPFileWorker.execute(request) { transport }
            #expect(result.outcome == .completed)
            #expect(result.transferredBytes == UInt64(bytes.count))
            #expect(await transport.uploaded == bytes)
            #expect(try Data(contentsOf: fixture.source) == bytes)
        }
    }
    @Test func changedSourceAndSymlinksFailBeforeUSBOpen() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let request = try MTPFileRequest.upload(sourceURL: fixture.source, to: sd)
        try Data("changed".utf8).write(to: fixture.source)
        let counts = FileOperationCounts()
        let result = await MTPFileWorker.execute(request) { await counts.factory(); return FileTransportFixture() }
        #expect(result.outcome == .failed)
        #expect(await counts.factories == 0)
        let alias = fixture.directory.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.source)
        #expect(throws: MTPFileError.localAccess) { try MTPFileUploadSource.review(alias) }
    }
    @Test func deviceSwapBeforeFirstMutationStopsUpload() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let request = try MTPFileRequest.upload(sourceURL: fixture.source, to: sd)
        let counts = FileOperationCounts(); let transport = FileTransportFixture()
        let result = await MTPFileWorker.execute(request, verifyDevice: { try await counts.verify(failOn: 3) }) { transport }
        #expect(result.outcome == .failed)
        #expect(await counts.verifies == 3)
        #expect(await transport.uploadCalls == 0)
    }
    @Test func failedOrCancelledUploadNeverRetriesOrDeletesPartialDeviceObject() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let request = try MTPFileRequest.upload(sourceURL: fixture.source, to: sd)
        let transport = FileTransportFixture(failUpload: true)
        let result = await MTPFileWorker.execute(request) { transport }
        #expect(result.outcome == .deviceStateUnknown)
        #expect(await transport.uploadCalls == 1)
        #expect(await transport.closed)
        #expect(result.message.contains("未删除"))
    }
    @Test func downloadPublishesExactBytesAndNeverOverwrites() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let destination = fixture.directory.appendingPathComponent("download.txt")
        let entry = MTPFileEntry(location: sd, name: "remote.txt", isDirectory: false, byteCount: 6)
        let request = MTPFileRequest.download(entry: entry, to: destination)
        let transport = FileTransportFixture(objects: [fileObject(1, name: "remote.txt")], children: [.max: [1]])
        let result = await MTPFileWorker.execute(request) { transport }
        #expect(result.outcome == .completed)
        #expect(try Data(contentsOf: destination) == Data("remote".utf8))
        let counts = FileOperationCounts()
        let second = await MTPFileWorker.execute(request) { await counts.factory(); return transport }
        #expect(second.outcome == .failed)
        #expect(await counts.factories == 0)
        #expect(try Data(contentsOf: destination) == Data("remote".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".SwitchShelf-partial-") })
    }
    @Test func failedDownloadCleansPartialAndNeverCreatesFinalName() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let destination = fixture.directory.appendingPathComponent("download.txt")
        let entry = MTPFileEntry(location: sd, name: "remote.txt", isDirectory: false, byteCount: 6)
        let transport = FileTransportFixture(objects: [fileObject(1, name: "remote.txt")], children: [.max: [1]], failDownload: true)
        let result = await MTPFileWorker.execute(.download(entry: entry, to: destination)) { transport }
        #expect(result.outcome == .failed)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).allSatisfy { !$0.hasPrefix(".SwitchShelf-partial-") })
    }
    @Test func staleDownloadMetadataNeverStartsGetObject() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let entry = MTPFileEntry(location: sd, name: "remote.txt", isDirectory: false, byteCount: 7)
        let transport = FileTransportFixture(objects: [fileObject(1, name: "remote.txt")], children: [.max: [1]])
        let result = await MTPFileWorker.execute(.download(entry: entry, to: fixture.directory.appendingPathComponent("download.txt"))) { transport }
        #expect(result.outcome == .failed)
        #expect(await transport.downloadCalls == 0)
    }
    @Test func failedReleaseNeverClaimsCompletedUpload() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let transport = FileTransportFixture(failClose: true)
        let result = await MTPFileWorker.execute(try .upload(sourceURL: fixture.source, to: sd)) { transport }
        #expect(result.outcome == .deviceStateUnknown)
        #expect(!result.releaseVerified)
    }
    @Test func downloadCleanupReceiptCannotDeleteReplacedFileOrFinalDestination() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        let destination = fixture.directory.appendingPathComponent("download.txt")
        let entry = MTPFileEntry(location: sd, name: "remote.txt", isDirectory: false, byteCount: 6)
        let request = MTPFileRequest.download(entry: entry, to: destination)
        let sink = try MTPFileDownloadSink(destination: destination)
        let artifact = try sink.partialFile()
        try FileManager.default.removeItem(at: artifact.url)
        try Data("replacement".utf8).write(to: artifact.url)
        #expect(throws: MTPFileError.localAccess) { try MTPFileWorker.cleanupDownloadPartial(request: request, artifact: artifact) }
        #expect(try Data(contentsOf: artifact.url) == Data("replacement".utf8))
    }
    @Test func unsafePathAndLargeUnknownDownloadsFailBeforeFactory() async throws {
        let fixture = try FileFixture(); defer { fixture.remove() }
        for location in [MTPFileLocation(storageName: "microSD card", components: [".."]), .init(storageName: "microSD card", components: ["a/b"])] {
            let counts = FileOperationCounts()
            let result = await MTPFileWorker.execute(.list(location: location)) { await counts.factory(); return FileTransportFixture() }
            #expect(result.outcome == .failed)
            #expect(await counts.factories == 0)
        }
        for size: UInt64? in [nil, UInt64(UInt32.max)] {
            let counts = FileOperationCounts()
            let entry = MTPFileEntry(location: sd, name: "large.bin", isDirectory: false, byteCount: size)
            let result = await MTPFileWorker.execute(.download(entry: entry, to: fixture.directory.appendingPathComponent("large.bin"))) { await counts.factory(); return FileTransportFixture() }
            #expect(result.outcome == .failed)
            #expect(await counts.factories == 0)
        }
    }
}
