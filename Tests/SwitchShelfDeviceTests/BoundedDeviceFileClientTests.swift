import Darwin
import Foundation
import Testing
@testable import SwitchShelfDevice

@Suite("Isolated device file client — fake processes only", .serialized)
struct BoundedDeviceFileClientTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwitchShelf-file-helper-fixture-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func responder(extra: String = "", exitCode: Int = 0) throws -> URL {
        try script("""
        exec /usr/bin/python3 - "$3" <<'PY'
        import json, pathlib, sys, os, stat
        p=pathlib.Path(sys.argv[1])
        q=json.loads((p/'request.json').read_text())
        assert stat.S_IMODE(p.stat().st_mode)==0o700
        assert stat.S_IMODE((p/'request.json').stat().st_mode)==0o600
        assert os.environ['SWITCHSHELF_DEVICE_FILE_TOKEN']
        r={'schemaVersion':1,'requestID':q['request']['id'],'result':{'requestID':q['request']['id'],'operation':q['request']['operation'],'outcome':'completed','storages':[],'transferredBytes':0,'releaseVerified':True,'message':'private request verified'}}
        \(extra)
        t=p/'result.tmp'
        t.write_text(json.dumps(r));t.chmod(0o600);t.rename(p/'result.json')
        sys.exit(\(exitCode))
        PY
        """)
    }
    @Test func receivesOnlyMatchingPrivateExitedResult() async throws {
        let url = try responder()
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        let request = MTPFileRequest.storages()
        let value = try await client.execute(request, timeoutSeconds: 2)
        #expect(value.requestID == request.id)
        #expect(value.message == "private request verified")
        #expect(value.outcome == .completed)
        #expect(!(await client.hasUnverifiedWorker))
    }
    @Test func mismatchedResultFencesEverySubsequentOperation() async throws {
        let url = try responder(extra: "r['result']['requestID']='different-request'")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        await #expect(throws: DeviceFileClientError.invalidResponse) {
            _ = try await client.execute(.storages(), timeoutSeconds: 2)
        }
        #expect(await client.hasUnverifiedWorker)
        await #expect(throws: DeviceFileClientError.unverifiedWorker) {
            _ = try await client.execute(.list(location: .init(storageName: "microSD card")), timeoutSeconds: 2)
        }
    }
    @Test func failedReleaseFencesBrowsingAndTransfers() async throws {
        let url = try responder(extra: "r['result']['releaseVerified']=False", exitCode: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        let result = try await client.execute(.storages(), timeoutSeconds: 2)
        #expect(!result.releaseVerified)
        #expect(await client.hasUnverifiedWorker)
        await #expect(throws: DeviceFileClientError.unverifiedWorker) {
            _ = try await client.execute(.storages(), timeoutSeconds: 2)
        }
    }
    @Test func missingSessionSignatureRejectsTransfersBeforeLaunch() async throws {
        let url = try script("exit 0\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let request = MTPFileRequest.download(entry: .init(location: .init(storageName: "microSD card"),
            name: "fixture.txt", isDirectory: false, byteCount: 1), to: URL(fileURLWithPath: "/private/tmp/fixture-not-created"))
        await #expect(throws: DeviceFileClientError.invalidRequest) {
            _ = try await BoundedDeviceFileClient(helperURL: url).execute(request, timeoutSeconds: 1)
        }
    }
    @Test func cancellationKeepsBusyUntilDirectProcessHasExited() async throws {
        let url = try script("exec /bin/sleep 20\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        let running = Task { try await client.execute(.storages(), timeoutSeconds: 10) }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await client.isBusy)
        await #expect(throws: DeviceFileClientError.busy) {
            _ = try await client.execute(.storages(), timeoutSeconds: 1)
        }
        running.cancel()
        await #expect(throws: CancellationError.self) { _ = try await running.value }
        #expect(!(await client.isBusy))
        #expect(await client.hasUnverifiedWorker)
    }
    @Test func deadlineReapsTermIgnoringDirectChild() async throws {
        let url = try script("trap '' TERM\nexec /bin/sleep 20\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        let start = ContinuousClock.now
        await #expect(throws: DeviceFileClientError.timeout) {
            _ = try await client.execute(.storages(), timeoutSeconds: 0.1)
        }
        #expect(start.duration(to: .now) < .seconds(4))
        #expect(!(await client.isBusy))
        #expect(await client.hasUnverifiedWorker)
    }
    @Test func contradictoryCompletedResultCannotClaimSuccess() async throws {
        let url = try responder(exitCode: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        await #expect(throws: DeviceFileClientError.invalidResponse) {
            _ = try await client.execute(.storages(), timeoutSeconds: 2)
        }
        #expect(await client.hasUnverifiedWorker)
    }
    @Test func slowProgressCallbackCannotHoldTheDeadline() async throws {
        let url = try responder(extra: """
        import time
        progress={'requestID':q['request']['id'],'phase':'fixture','bytesTransferred':0,'updatedAt':0}
        f=p/'progress.json'; f.write_text(json.dumps(progress)); f.chmod(0o600)
        time.sleep(5)
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        let started = ContinuousClock.now
        let received = FileProgressEvents()
        await #expect(throws: DeviceFileClientError.timeout) {
            _ = try await client.execute(.storages(), timeoutSeconds: 0.8) { value in
                received.append(value)
                try? await Task.sleep(for: .seconds(2))
            }
        }
        #expect(started.duration(to: .now) < .seconds(1.8))
        #expect(!received.values.isEmpty)
        #expect(!(await client.isBusy))
    }
    @Test func cooperativeCancellationWithVerifiedReleaseDoesNotFence() async throws {
        let url = try responder(extra: """
        import time
        while not (p/'cancel').exists(): time.sleep(0.02)
        r['result']['outcome']='cancelled'
        """, exitCode: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let client = BoundedDeviceFileClient(helperURL: url)
        let running = Task { try await client.execute(.storages(), timeoutSeconds: 5) }
        try await Task.sleep(for: .milliseconds(450))
        running.cancel()
        await #expect(throws: CancellationError.self) { _ = try await running.value }
        #expect(!(await client.isBusy))
        #expect(!(await client.hasUnverifiedWorker))
    }
    @Test func streamingProgressJournalBoundsWritesAndPreservesFinalBytes() async {
        let events = FileProgressEvents()
        let journal = DeviceFileProgressJournal { events.append($0) }
        let id = UUID().uuidString
        for bytes in 0..<100 {
            await journal.publish(.init(requestID: id, phase: "下载中", bytesTransferred: UInt64(bytes), totalBytes: 100))
        }
        await journal.finish(.init(requestID: id, operation: .download, outcome: .completed,
            transferredBytes: 100, message: "fixture"))
        let values = events.values
        #expect(values.count < 10)
        #expect(values.first?.bytesTransferred == 0)
        #expect(values.last?.bytesTransferred == 100)
        #expect(values.last?.phase == "已完成")
    }
}

private final class FileProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MTPFileProgress] = []
    func append(_ value: MTPFileProgress) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [MTPFileProgress] { lock.lock(); defer { lock.unlock() }; return stored }
}
