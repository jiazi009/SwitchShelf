import Darwin
import Foundation
import Testing
@testable import SwitchShelfDevice

private struct InstallFixture {
    let directory: URL
    let source: URL
    let attempts: URL
    init() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let canonical = try #require(realpath(temporary.path, nil))
        defer { free(canonical) }
        directory = URL(fileURLWithPath: String(cString: canonical))
        source = directory.appendingPathComponent("fixture.nsp")
        attempts = directory.appendingPathComponent("attempts")
        try Data(0..<13).write(to: source)
        try FileManager.default.createDirectory(at: attempts, withIntermediateDirectories: true)
    }
    func request() throws -> SphairaInstallRequest {
        try .review(sourceURL: source, allowedRoot: directory, expectedBytes: 13, intendedTarget: "sd")
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func script(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".py")
        try ("#!/usr/bin/python3\nimport os,sys,json,time,signal\nd=sys.argv[3]\n" + body).write(to: url, atomically: true, encoding: .utf8)
        #expect(chmod(url.path, 0o700) == 0)
        return url
    }
}
private actor FactoryObservation {
    var opens = 0
    func opened() -> Int { opens += 1; return opens }
}
private actor CallbackLatch {
    var entered = false
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func block() async {
        entered = true
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor BusyTransport: SphairaUploadTransport {
    var closeFails = false
    init(closeFails: Bool = false) { self.closeFails = closeFails }
    func inspectSession() -> SphairaUploadSession {
        .init(deviceVersion: "Sphaira/fixture", supportedOperations: [0x9808, 0x100d],
              storages: [.init(id: 9, name: "Games"), .init(id: 8, name: "Install")], lastTransaction: 20)
    }
    func sendCommand(_ container: Data) {}
    func beginData(_ header: Data) {}
    func writeData(_ bytes: Data) {}
    func endData() {}
    func receiveResponse() -> Data {
        var data = Data()
        PTPCodec.append(UInt32(12), to: &data)
        PTPCodec.append(UInt16(3), to: &data)
        PTPCodec.append(UInt16(0x2019), to: &data)
        PTPCodec.append(UInt32(21), to: &data)
        return data
    }
    func close() throws { if closeFails { throw SphairaUploadError.invalidResponse } }
}
private actor WorkerTransport: SphairaUploadTransport {
    var responses = 0
    var closed = false
    func inspectSession() -> SphairaUploadSession {
        .init(deviceVersion: "Sphaira/fixture", supportedOperations: [0x9808, 0x100d],
              storages: [.init(id: 9, name: "Games"), .init(id: 8, name: "Install")], lastTransaction: 20)
    }
    func sendCommand(_ container: Data) {}
    func beginData(_ header: Data) {}
    func writeData(_ bytes: Data) {}
    func endData() {}
    func receiveResponse() -> Data {
        responses += 1
        var data = Data()
        let parameters: [UInt32] = responses == 1 ? [8, 0, 50] : []
        PTPCodec.append(UInt32(12 + parameters.count * 4), to: &data)
        PTPCodec.append(UInt16(3), to: &data); PTPCodec.append(UInt16(0x2001), to: &data)
        PTPCodec.append(UInt32(responses == 1 ? 21 : 22), to: &data)
        for value in parameters { PTPCodec.append(value, to: &data) }
        return data
    }
    func close() { closed = true }
}

@Suite("sphaira installation confirmation, worker and process isolation — no USB")
struct SphairaInstallerTests {
    @Test func unconfirmedAndChangedReviewedFilesFailBeforeTransportFactory() async throws {
        for mutation in [false, true] {
            let fixture = try InstallFixture(); defer { fixture.remove() }
            let reviewed = try fixture.request()
            let request = mutation ? reviewed.confirmed() : reviewed
            if mutation {
                let file = try FileHandle(forWritingTo: fixture.source)
                try file.write(contentsOf: Data([255])); try file.close()
            }
            let observer = FactoryObservation()
            let result = await SphairaInstallWorker.execute(request: request, directory: fixture.attempts,
                leaseURL: fixture.directory.appendingPathComponent("lease")) {
                    _ = await observer.opened(); return WorkerTransport()
                }
            #expect(result.transfer.outcome == .notStarted)
            #expect(await observer.opens == 0)
        }
    }

    @Test func failedJournalOrBusyLeasePrecedesUSBOpen() async throws {
        for busy in [false, true] {
            let fixture = try InstallFixture(); defer { fixture.remove() }
            let request = try fixture.request().confirmed()
            let leaseURL = fixture.directory.appendingPathComponent("lease")
            let lease = busy ? try DeviceLease.acquire(at: leaseURL) : nil
            defer { lease?.release() }
            let observer = FactoryObservation()
            let directory = busy ? fixture.attempts : fixture.directory.appendingPathComponent("missing/no-directory")
            let result = await SphairaInstallWorker.execute(request: request, directory: directory, leaseURL: leaseURL) {
                _ = await observer.opened(); return WorkerTransport()
            }
            #expect(result.transfer.outcome == .notStarted)
            #expect(await observer.opens == 0)
        }
    }

    @Test func deviceBusyBeforeAnyBytesWaitsThenSendsTheSameFile() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let request = try fixture.request().confirmed()
        let observer = FactoryObservation()
        let result = await SphairaInstallWorker.execute(request: request, directory: fixture.attempts,
            leaseURL: fixture.directory.appendingPathComponent("lease"),
            busyInterval: .milliseconds(1), busyAttempts: 3) {
                let opens = await observer.opened()
                return opens == 1 ? BusyTransport() : WorkerTransport()
            }
        #expect(result.transfer.outcome == .transferredAwaitingConfirmation)
        #expect(result.transfer.bytesSubmitted == 13)
        #expect(await observer.opens == 2)
        let state = try SphairaAttemptFile.load(SphairaInstallProgress.self, at: fixture.attempts.appendingPathComponent("state.json"))
        #expect(state.phase == "transferring" && state.bytesSubmitted == 13)
        #expect(try Data(contentsOf: fixture.source) == Data(0..<13))
    }

    @Test func deviceBusyWithUnverifiedReleaseNeverRetries() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let request = try fixture.request().confirmed()
        let observer = FactoryObservation()
        let result = await SphairaInstallWorker.execute(request: request, directory: fixture.attempts,
            leaseURL: fixture.directory.appendingPathComponent("lease"),
            busyInterval: .milliseconds(1), busyAttempts: 3) {
                _ = await observer.opened()
                return BusyTransport(closeFails: true)
            }
        #expect(result.transfer.failure == .deviceBusy)
        #expect(result.transfer.bytesSubmitted == 0)
        #expect(!result.transfer.releaseVerified)
        #expect(await observer.opens == 1)
    }

    @Test func persistentDeviceBusySendsNothingAndStops() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let request = try fixture.request().confirmed()
        let observer = FactoryObservation()
        let result = await SphairaInstallWorker.execute(request: request, directory: fixture.attempts,
            leaseURL: fixture.directory.appendingPathComponent("lease"),
            busyInterval: .milliseconds(1), busyAttempts: 2) {
                _ = await observer.opened()
                return BusyTransport()
            }
        #expect(result.transfer.failure == .deviceBusy)
        #expect(result.transfer.bytesSubmitted == 0)
        #expect(result.transfer.outcome == .notStarted)
        #expect(await observer.opens == 2)
        #expect(try Data(contentsOf: fixture.source) == Data(0..<13))
    }

    @Test func durableWorkerStateAndReplayPreservesOriginalResult() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let request = try fixture.request().confirmed()
        let transport = WorkerTransport()
        let result = await SphairaInstallWorker.execute(request: request, directory: fixture.attempts,
            leaseURL: fixture.directory.appendingPathComponent("lease")) { transport }
        #expect(result.transfer.outcome == .transferredAwaitingConfirmation)
        #expect(!result.processExitVerified) // Only its parent can establish this fact.
        #expect(await transport.closed)
        let output = fixture.attempts.appendingPathComponent("worker-result.json")
        let original = try Data(contentsOf: output)
        let state = try SphairaAttemptFile.load(SphairaInstallProgress.self, at: fixture.attempts.appendingPathComponent("state.json"))
        #expect(state.phase == "transferring" && state.bytesSubmitted == 13)
        let replay = await SphairaInstallWorker.execute(request: request, directory: fixture.attempts,
            leaseURL: fixture.directory.appendingPathComponent("lease")) { transport }
        #expect(replay.transfer.outcome == .notStarted)
        #expect(try Data(contentsOf: output) == original)
        #expect(try Data(contentsOf: fixture.source) == Data(0..<13))
    }

    @Test func supervisorRequiresExplicitConfirmationBeforeLaunching() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let helper = try fixture.script("raise RuntimeError('must not launch')\n")
        let installer = SphairaInstaller(helperURL: helper, recordsURL: fixture.attempts)
        let request = try fixture.request()
        await #expect(throws: SphairaInstallError.self) { try await installer.install(request) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.attempts.path).isEmpty)
    }

    @Test func directChildExitIsVerifiedIndependentlyOfWorkerClaim() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let helper = try fixture.script("""
        r=json.load(open(os.path.join(d,'request.json')))
        result={'schemaVersion':1,'requestID':r['id'],'transfer':{'outcome':'transferredAwaitingConfirmation','bytesSubmitted':r['byteCount'],'failure':None,'releaseVerified':True},'message':'fixture only','processExitVerified':False}
        json.dump(result,open(os.path.join(d,'worker-result.json'),'w'))
        """)
        let request = try fixture.request().confirmed()
        let installer = SphairaInstaller(helperURL: helper, recordsURL: fixture.attempts)
        let result = try await installer.install(request, timeoutSeconds: 10, stallSeconds: 10)
        #expect(result.processExitVerified)
        #expect(result.transfer.outcome == .transferredAwaitingConfirmation)
        let record = fixture.attempts.appendingPathComponent(request.id).appendingPathComponent("supervisor-result.json")
        #expect(try SphairaAttemptFile.load(SphairaInstallReport.self, at: record).processExitVerified)
        let original = try Data(contentsOf: record)
        await #expect(throws: SphairaInstallError.self) { try await installer.install(request) }
        #expect(try Data(contentsOf: record) == original)
    }

    @Test func inconsistentOrMissingChildResultsStayUnknown() async throws {
        for badResult in [false, true] {
            let fixture = try InstallFixture(); defer { fixture.remove() }
            let helper = try fixture.script(badResult ? """
            r=json.load(open(os.path.join(d,'request.json')))
            result={'schemaVersion':1,'requestID':r['id'],'transfer':{'outcome':'transferredAwaitingConfirmation','bytesSubmitted':0,'failure':None,'releaseVerified':True},'message':'invalid','processExitVerified':True}
            json.dump(result,open(os.path.join(d,'worker-result.json'),'w'))
            """ : "pass\n")
            let installer = SphairaInstaller(helperURL: helper, recordsURL: fixture.attempts)
            let result = try await installer.install(fixture.request().confirmed(), timeoutSeconds: 10, stallSeconds: 10)
            #expect(result.processExitVerified)
            #expect(result.transfer.outcome == .deviceStateUnknown)
        }
    }

    @Test func deadlineKillsTermIgnoringDirectChildAndVerifiesExit() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let helper = try fixture.script("signal.signal(signal.SIGTERM, signal.SIG_IGN)\nopen(os.path.join(d,'pid'),'w').write(str(os.getpid()))\ntime.sleep(30)\n")
        let request = try fixture.request().confirmed()
        let installer = SphairaInstaller(helperURL: helper, recordsURL: fixture.attempts)
        let result = try await installer.install(request, timeoutSeconds: 5, stallSeconds: 10)
        #expect(result.processExitVerified)
        #expect(result.transfer.outcome == .deviceStateUnknown)
        let pidFile = fixture.attempts.appendingPathComponent(request.id).appendingPathComponent("pid")
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test func blockedProgressCallbackCannotBlockDeadlineOrProcessExit() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let helper = try fixture.script("""
        r=json.load(open(os.path.join(d,'request.json')))
        state={'requestID':r['id'],'phase':'opening','bytesSubmitted':0,'totalBytes':r['byteCount'],'updatedAt':time.time()-978307200}
        json.dump(state,open(os.path.join(d,'state.json'),'w'))
        time.sleep(30)
        """)
        let installer = SphairaInstaller(helperURL: helper, recordsURL: fixture.attempts)
        let latch = CallbackLatch()
        let result = try await installer.install(fixture.request().confirmed(), timeoutSeconds: 5, stallSeconds: 10) { _ in
            await latch.block()
        }
        #expect(await latch.entered)
        #expect(result.processExitVerified)
        #expect(result.transfer.outcome == .deviceStateUnknown)
        await latch.release()
    }

    @Test func cancellationWaitsForDirectChildExit() async throws {
        let fixture = try InstallFixture(); defer { fixture.remove() }
        let helper = try fixture.script("open(os.path.join(d,'pid'),'w').write(str(os.getpid()))\ntime.sleep(30)\n")
        let request = try fixture.request().confirmed()
        let installer = SphairaInstaller(helperURL: helper, recordsURL: fixture.attempts)
        let operation = Task { try await installer.install(request, timeoutSeconds: 10, stallSeconds: 10) }
        let marker = fixture.attempts.appendingPathComponent(request.id).appendingPathComponent("pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: marker.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        operation.cancel()
        let result = try await operation.value
        #expect(result.processExitVerified)
        #expect(result.transfer.failure == .cancelled)
        #expect(result.transfer.outcome == .deviceStateUnknown)
    }
}
