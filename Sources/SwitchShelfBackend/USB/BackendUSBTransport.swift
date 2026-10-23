import Foundation
import CDBIBackendUSB

/// Shared owner must be provided by composition and must coordinate with MTP.
/// A failed release must remain fenced; do not make a new lease available.
/// A failed acquire other than `releaseUnverified` MUST leave no ownership behind.
/// An uncertain acquisition retains the process fence as well.
public protocol BackendUSBDeviceLease: Sendable {
    func acquire() async throws
    func release() async throws
}

/// Injectable driver. Implementations must not retry an uncertain write and must
/// keep native ownership alive through every awaited operation.
public protocol BackendUSBDriver: Sendable {
    func open() async throws
    func read(maximumLength: Int, timeoutMilliseconds: UInt32) async throws -> Data
    func write(_ data: Data, timeoutMilliseconds: UInt32) async throws
    func close() async throws
}

// Internal for @testable isolated fake-driver tests only. Public opens always use
// production; no reset API exists and failed release permanently fences a gate.
actor BackendUSBProcessGate {
    static let production = BackendUSBProcessGate()
    private var held = false
    func acquire() throws {
        guard !held else { throw BackendError.busy }
        held = true
    }
    func release() { held = false }
}

/// Explicit-open Backend stream. `init` cannot access hardware; only `open`
/// can call the native driver. Not wired to any production UI or CLI in this wave.
/// Close during I/O returns busy; a failed release fences the process permanently.
public actor BackendUSBTransport: BackendByteTransport {
    public static let maximumTransferLength = 1_048_576
    public static let maximumTimeoutMilliseconds: UInt32 = 60_000
    private let driver: any BackendUSBDriver
    private let lease: any BackendUSBDeviceLease
    private let gate: BackendUSBProcessGate
    private var active = false
    private var closed = false

    private init(driver: any BackendUSBDriver, lease: any BackendUSBDeviceLease,
                 gate: BackendUSBProcessGate) {
        self.driver = driver
        self.lease = lease
        self.gate = gate
    }

    public static func open(lease: any BackendUSBDeviceLease) async throws -> BackendUSBTransport {
        try await open(lease: lease, driver: NativeBackendUSBDriver(), gate: .production)
    }

    /// Driver injection is for hardware-free validation. Both public overloads
    /// unconditionally use the single production gate.
    public static func open(lease: any BackendUSBDeviceLease,
                            driver: any BackendUSBDriver) async throws -> BackendUSBTransport {
        try await open(lease: lease, driver: driver, gate: .production)
    }

    /// Internal isolated gate is only usable by in-module code and @testable fakes.
    /// Production overloads cannot pass or reset a different gate.
    static func open(lease: any BackendUSBDeviceLease, driver: any BackendUSBDriver,
                     gate: BackendUSBProcessGate) async throws -> BackendUSBTransport {
        try Task.checkCancellation()
        try await gate.acquire()
        // A lease failure is known-safe only when it is not releaseUnverified.
        do {
            try Task.checkCancellation()
            try await lease.acquire()
        } catch {
            if (error as? BackendError) == .releaseUnverified {
                throw BackendError.releaseUnverified
            }
            await gate.release()
            throw error
        }
        do {
            try Task.checkCancellation()
            try await driver.open() // waits even if caller is cancelled mid-open
        } catch {
            if (error as? BackendError) == .releaseUnverified {
                // Native open may still own an interface. Never close it blindly.
                throw BackendError.releaseUnverified
            }
            try await releaseAfterFailedOpen(lease: lease, gate: gate)
            throw error
        }
        if Task.isCancelled {
            // Open succeeded after cancellation: close before releasing either gate.
            do { try await driver.close() }
            catch { throw BackendError.releaseUnverified }
            try await releaseAfterFailedOpen(lease: lease, gate: gate)
            throw BackendError.cancelled
        }
        return BackendUSBTransport(driver: driver, lease: lease, gate: gate)
    }

    private static func releaseAfterFailedOpen(lease: any BackendUSBDeviceLease,
                                               gate: BackendUSBProcessGate) async throws {
        do { try await lease.release() }
        catch { throw BackendError.releaseUnverified }
        await gate.release()
    }

    private func begin() throws {
        guard !closed else { throw BackendError.unavailable }
        guard !active else { throw BackendError.busy }
        active = true
    }
    private func validate(_ size: Int, _ timeout: UInt32) throws {
        guard size > 0, size <= Self.maximumTransferLength,
              timeout > 0, timeout <= Self.maximumTimeoutMilliseconds else { throw BackendError.invalidPlan }
    }
    public func read(maximumLength: Int, timeoutMilliseconds: UInt32) async throws -> Data {
        try validate(maximumLength, timeoutMilliseconds)
        try begin()
        defer { active = false }
        try Task.checkCancellation()
        let bytes = try await driver.read(maximumLength: maximumLength, timeoutMilliseconds: timeoutMilliseconds)
        guard !bytes.isEmpty, bytes.count <= maximumLength else { throw BackendError.transport }
        try Task.checkCancellation() // native work has finished; gate remains held
        return bytes // fragments are valid, never pad or invent bytes
    }
    public func write(_ data: Data, timeoutMilliseconds: UInt32) async throws {
        try validate(data.count, timeoutMilliseconds)
        try begin()
        defer { active = false }
        try Task.checkCancellation()
        // A driver success is a full transfer. Driver failures are not retried.
        try await driver.write(data, timeoutMilliseconds: timeoutMilliseconds)
        try Task.checkCancellation() // cancellation cannot interrupt native I/O
    }
    public func close() async throws {
        guard !closed else { throw BackendError.unavailable }
        guard !active else { throw BackendError.busy }
        active = true
        defer { active = false }
        do { try await driver.close() }
        catch { closed = true; throw BackendError.releaseUnverified }
        closed = true
        do { try await lease.release(); await gate.release() }
        catch { throw BackendError.releaseUnverified }
    }
}

/// Opaque C pointer remains inside this serial, unchecked-sendable box; the actor
/// fences concurrent calls, and detached blocking IOKit work is awaited to completion.
private final class NativeHandle: @unchecked Sendable {
    var pointer: OpaquePointer?
}

final class NativeBackendUSBDriver: BackendUSBDriver, @unchecked Sendable {
    private let handle = NativeHandle()
    public init() {} // No discovery, open, or hardware access here.
    private func status(_ value: Int32) -> BackendError {
        switch value {
        case Int32(SS_USB_BUSY): .busy
        case Int32(SS_USB_TIMEOUT): .timeout
        case Int32(SS_USB_DISCONNECTED): .disconnected
        case Int32(SS_USB_UNAVAILABLE), Int32(SS_USB_AMBIGUOUS), Int32(SS_USB_DESCRIPTOR): .unavailable
        case Int32(SS_USB_RELEASE): .releaseUnverified
        default: .transport
        }
    }
    public func open() async throws {
        let result = await Task.detached { [handle] in
            var code: Int32 = 0
            return Int32(ss_usb_open(&handle.pointer, &code))
        }.value
        guard result == SS_USB_OK else { throw status(result) }
    }
    public func read(maximumLength: Int, timeoutMilliseconds: UInt32) async throws -> Data {
        let result = await Task.detached { [handle] in
            var data = Data(count: maximumLength)
            var count = UInt32(maximumLength), code: Int32 = 0
            let status = data.withUnsafeMutableBytes { bytes in
                ss_usb_read(handle.pointer, bytes.baseAddress, &count, timeoutMilliseconds, &code)
            }
            return (Int32(status), data.prefix(Int(count)))
        }.value
        guard result.0 == SS_USB_OK else { throw status(result.0) }
        return Data(result.1)
    }
    public func write(_ data: Data, timeoutMilliseconds: UInt32) async throws {
        let result = await Task.detached { [handle] in
            var code: Int32 = 0
            return data.withUnsafeBytes { bytes in
                Int32(ss_usb_write(handle.pointer, bytes.baseAddress, UInt32(data.count), timeoutMilliseconds, &code))
            }
        }.value
        guard result == SS_USB_OK else { throw status(result) }
    }
    public func close() async throws {
        let result = await Task.detached { [handle] in
            var code: Int32 = 0
            return Int32(ss_usb_close(handle.pointer, &code))
        }.value
        guard result == SS_USB_OK else { throw status(result) }
        handle.pointer = nil
    }
}
