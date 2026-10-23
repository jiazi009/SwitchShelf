import Foundation
import Testing
@testable import SwitchShelfDevice

@Suite("Machine-wide device lease", .serialized)
struct DeviceLeaseTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchShelf-lease-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("device-lease.lock")
    }

    @Test("A second handle is busy until the first releases")
    func mutualExclusion() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try DeviceLease.acquire(at: url)
        defer { first.release() }
        #expect(first.isHeld)
        #expect(throws: DeviceLeaseError.busy) { _ = try DeviceLease.acquire(at: url) }
        first.release()
        #expect(!first.isHeld)
        let second = try DeviceLease.acquire(at: url)
        second.release()
    }

    @Test("A different path does not conflict")
    func independentPaths() throws {
        let first = try DeviceLease.acquire(at: temporaryURL())
        let second = try DeviceLease.acquire(at: temporaryURL())
        #expect(first.isHeld && second.isHeld)
        first.release(); second.release()
    }
}
