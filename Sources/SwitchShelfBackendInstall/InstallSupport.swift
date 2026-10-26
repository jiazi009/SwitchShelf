import Foundation
import SwitchShelfBackend
import SwitchShelfDevice

/// Composition seam: production opens the real native Backend interface; tests
/// inject a scripted transport and never touch hardware.
public protocol BackendInstallTransportProviding: Sendable {
    func makeTransport() async throws -> any BackendByteTransport
}

/// The same machine-wide `flock` used by the MTP probe, adapted to the Backend
/// session contract. The app, probe and this helper therefore cannot open the
/// device concurrently.
public actor SharedDeviceLease: BackendUSBDeviceLease {
    private let url: URL
    private var lease: DeviceLease?

    public init(url: URL = DeviceLease.defaultURL) {
        self.url = url
    }

    public func acquire() throws {
        guard lease == nil else { throw BackendError.busy }
        do {
            lease = try DeviceLease.acquire(at: url)
        } catch let error as DeviceLeaseError {
            throw error == .busy ? BackendError.busy : BackendError.unavailable
        } catch {
            throw BackendError.unavailable
        }
    }

    public func release() {
        let current = lease
        lease = nil
        current?.release()
    }
}

/// Explicit-open native provider. No discovery or hardware access happens before
/// `makeTransport`; a failed open leaves no ownership behind (except the fenced
/// `releaseUnverified` case, which the transport itself refuses to retry).
public struct USBBackendTransportProvider: BackendInstallTransportProviding {
    private let leaseURL: URL

    public init(leaseURL: URL = DeviceLease.defaultURL) {
        self.leaseURL = leaseURL
    }

    public func makeTransport() async throws -> any BackendByteTransport {
        try await BackendUSBTransport.open(lease: SharedDeviceLease(url: leaseURL))
    }
}
