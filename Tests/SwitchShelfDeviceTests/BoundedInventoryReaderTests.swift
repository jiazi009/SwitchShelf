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

    @Test("Selected route is passed to the isolated probe")
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
        let native = try await reader.readInventory(timeoutSeconds: 1)
        let usb = try await reader.readInventory(timeoutSeconds: 1, transport: .libusb)
        #expect(native.deviceID == "native")
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
        let json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"partial\",\"inventory\":\(String(decoding: data, as: UTF8.self))}"
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
        let json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"status\":\"ok\",\"inventory\":\(String(decoding: data, as: UTF8.self))}"
        let url = try script("printf '%s\\n' '\(json)'\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ProbeError.self) {
            _ = try await BoundedInventoryReader(probeURL: url).readInventory(timeoutSeconds: 1)
        }
    }

    @Test("Session access failure retains an actionable MTP error")
    func sessionAccessFailure() async throws {
        let json = #"{"schemaVersion":1,"mode":"inventory","status":"error","error":{"code":"accessDeniedOrBusy","message":"fixture"}}"#
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
