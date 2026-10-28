import Darwin
import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfDevice

@Suite("Isolated app inventory process", .serialized)
struct BoundedInventoryReaderTests {
    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelf-fake-probe-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test("The default and explicit inventory route are both libusb")
    func selectedRoute() async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let inventory = InstalledInventory(deviceID: "ROUTE", isComplete: true)
        let data = try encoder.encode(inventory)
        let json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"ok\",\"transport\":\"ROUTE\",\"inventory\":\(String(decoding: data, as: UTF8.self))}"
        let scriptBody = "if [ \"$3\" = libusb ]; then route=libusb; else route=native; fi\nprintf '%s\\n' '\(json)' | sed \"s/ROUTE/$route/g\"\nexit 0\n"
        let url = try script(scriptBody)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BoundedInventoryReader(probeURL: url)
        let defaultResult = try await reader.readInventory(timeoutSeconds: 1)
        let usb = try await reader.readInventory(timeoutSeconds: 1, transport: .libusb)
        #expect(defaultResult.deviceID == "libusb")
        #expect(usb.deviceID == "libusb")
    }

    @Test("A probe claiming the wrong route cannot be accepted")
    func mismatchedRoute() async throws {
        let inventory = InstalledInventory(deviceID: "fixture", isComplete: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(inventory)
        let json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"ok\",\"transport\":\"native\",\"inventory\":\(String(decoding: data, as: UTF8.self))}"
        let url = try script("printf '%s\\n' '\(json)'\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ProbeError.self) {
            _ = try await BoundedInventoryReader(probeURL: url).readInventory(timeoutSeconds: 1, transport: .libusb)
        }
    }

    @Test("Partial JSON remains partial and comes from an exited process")
    func partial() async throws {
        let inventory = InstalledInventory(deviceID: "fixture-session", isComplete: false,
                                           issues: ["Installed games unavailable"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(inventory)
        let json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"partial\",\"transport\":\"libusb\",\"inventory\":\(String(decoding: data, as: UTF8.self))}"
        let url = try script("printf '%s\\n' '\(json)'\nexit 2\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await BoundedInventoryReader(probeURL: url).readInventory(timeoutSeconds: 1)
        #expect(result.isComplete == false)
        #expect(result.issues == ["Installed games unavailable"])
    }

    @Test("Contradictory success/coverage/exit cannot claim a complete inventory")
    func inconsistentResult() async throws {
        let inventory = InstalledInventory(deviceID: "fixture-session", isComplete: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(inventory)
        let json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"ok\",\"transport\":\"libusb\",\"inventory\":\(String(decoding: data, as: UTF8.self))}"
        let url = try script("printf '%s\\n' '\(json)'\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ProbeError.self) {
            _ = try await BoundedInventoryReader(probeURL: url).readInventory(timeoutSeconds: 1)
        }
    }

    @Test("Session access failure retains an actionable MTP error")
    func sessionAccessFailure() async throws {
        let json = #"{"schemaVersion":1,"mode":"inventory","status":"error","transport":"libusb","error":{"code":"accessDeniedOrBusy","message":"fixture"}}"#
        let url = try script("printf '%s\\n' '\(json)'\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await BoundedInventoryReader(probeURL: url).readInventory(timeoutSeconds: 1)
            Issue.record("Expected a session access failure")
        } catch ProbeError.sessionUnavailable {
            #expect(ProbeError.sessionUnavailable.localizedDescription.contains("OpenMTP"))
        }
    }

    @Test("An unverified USB worker exit fences all retries in this app process")
    func unverifiedWorkerExit() async throws {
        let url = try script("printf '%s\\n' '{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"error\",\"error\":{\"code\":\"workerExitUnverified\",\"message\":\"unknown\"}}'\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BoundedInventoryReader(probeURL: url)
        do {
            _ = try await reader.readInventory(timeoutSeconds: 1)
            Issue.record("Unverified exit must fail")
        } catch ProbeError.previousProcessUnverified {}
        do {
            _ = try await reader.readInventory(timeoutSeconds: 1)
            Issue.record("Second attempt must not spawn another process")
        } catch ProbeError.previousProcessUnverified {}
    }

    @Test("Unverified exit fences retries even when the probe claims the wrong route")
    func mismatchedRouteUnverifiedExit() async throws {
        let url = try script("printf '%s\\n' '{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"error\",\"transport\":\"native\",\"error\":{\"code\":\"workerExitUnverified\",\"message\":\"unknown\"}}'\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BoundedInventoryReader(probeURL: url)
        for _ in 0..<2 {
            do {
                _ = try await reader.readInventory(timeoutSeconds: 1, transport: .libusb)
                Issue.record("Unverified exit must fence retries")
            } catch ProbeError.previousProcessUnverified {}
        }
    }

    @Test("Supervisor signal, malformed output and inconsistent exit fence later opens")
    func unknownWorkerExitFencesAllRetries() async throws {
        for failureBody in [
            "kill -TERM $$",
            "printf '%s\\n' 'malformed'; exit 1",
            "printf '%s\\n' '{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"error\",\"transport\":\"libusb\",\"error\":{\"code\":\"busy\",\"message\":\"fixture\"}}'; exit 0"
        ] {
            let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: marker) }
            let url = try script("printf '%s\\n' started >> '\(marker.path)'\n" + failureBody + "\n")
            defer { try? FileManager.default.removeItem(at: url) }
            let reader = BoundedInventoryReader(probeURL: url)
            for _ in 0..<2 {
                do {
                    _ = try await reader.readInventory(timeoutSeconds: 1)
                    Issue.record("Unknown worker exit must fence every later open")
                } catch ProbeError.previousProcessUnverified {}
            }
            #expect(await reader.hasUnverifiedWorker)
            #expect(try String(contentsOf: marker, encoding: .utf8) == "started\n")
        }
    }

    @Test("Cancellation asks the supervisor to reap its worker before retry")
    func cancellationWaitsForVerifiedWorkerExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let workerPID = directory.appendingPathComponent("worker-pid")
        let retry = directory.appendingPathComponent("retry")
        let inventory = InstalledInventory(deviceID: "fixture", isComplete: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(inventory)
        let json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"ok\",\"transport\":\"libusb\",\"inventory\":\(String(decoding: data, as: UTF8.self))}"
        let url = try script("""
        if [ -e '\(retry.path)' ]; then printf '%s\\n' '\(json)'; exit 0; fi
        /bin/sleep 30 &
        worker=$!
        printf '%s' "$worker" > '\(workerPID.path)'
        touch '\(ready.path)'
        while [ ! -e "$SWITCHSHELF_PROBE_CANCEL_PATH" ]; do /bin/sleep 0.02; done
        kill "$worker"
        wait "$worker" 2>/dev/null
        printf '%s\\n' '{"schemaVersion":1,"mode":"inventory","status":"error","transport":"libusb","error":{"code":"cancelled","message":"worker reaped"}}'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BoundedInventoryReader(probeURL: url)
        let task = Task { try await reader.readInventory(timeoutSeconds: 30) }
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: ready.path))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(started.duration(to: .now) < .seconds(3))
        #expect(await !reader.hasUnverifiedWorker)
        let pid = try #require(Int32(String(contentsOf: workerPID, encoding: .utf8)))
        #expect(Darwin.kill(pid, 0) == -1 && errno == ESRCH)
        try Data().write(to: retry)
        #expect(try await reader.readInventory(timeoutSeconds: 1).isComplete)
    }

    @Test("A task cancelled before reading launches no helper")
    func cancelledBeforeLaunch() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let url = try script("touch '\(marker.path)'\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BoundedInventoryReader(probeURL: url)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.readInventory(timeoutSeconds: 1)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(await !reader.hasUnverifiedWorker)
    }

    @Test("An unresponsive supervisor is fenced after cancellation")
    func unresponsiveCancellationFences() async throws {
        let url = try script("exec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BoundedInventoryReader(probeURL: url)
        let task = Task { try await reader.readInventory(timeoutSeconds: 30) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Unresponsive supervisor must fence")
        } catch ProbeError.previousProcessUnverified {}
        #expect(await reader.hasUnverifiedWorker)
        do {
            _ = try await reader.readInventory(timeoutSeconds: 1)
            Issue.record("A fenced reader must not spawn again")
        } catch ProbeError.previousProcessUnverified {}
    }

    @Test("A hung fake executable is stopped before a retry can begin")
    func timeoutAndSerialization() async throws {
        let url = try script("exec /bin/sleep 10\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = BoundedInventoryReader(probeURL: url)
        let first = Task { try await reader.readInventory(timeoutSeconds: 1) }
        try await Task.sleep(for: .milliseconds(250))
        await #expect(throws: DeviceServiceError.self) {
            _ = try await reader.readInventory(timeoutSeconds: 1)
        }
        await #expect(throws: ProbeError.self) { _ = try await first.value }
    }
}
