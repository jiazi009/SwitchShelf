import Foundation
import CDBIBackendUSB

/// Shared owner must be provided by composition and must coordinate with MTP.
/// A failed release must remain fenced; do not make a new lease available.
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

private actor ProcessGate {
    static let shared = ProcessGate()
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
    private var active = false
    private var closed = false

    private init(driver: any BackendUSBDriver, lease: any BackendUSBDeviceLease) {
        self.driver = driver
        self.lease = lease
    }

    public static func open(lease: any BackendUSBDeviceLease) async throws -> BackendUSBTransport {
        try await open(lease: lease, driver: NativeBackendUSBDriver())
    }

    /// Driver injection is for hardware-free validation. Only the caller's shared
    /// MTP/Backend lease may authorize native open in production composition.
    public static func open(lease: any BackendUSBDeviceLease,
                            driver: any BackendUSBDriver) async throws -> BackendUSBTransport {
        try await ProcessGate.shared.acquire()
        do {
            try await lease.acquire()
        } catch {
            await ProcessGate.shared.release()
            throw error
        }
        do {
            try await driver.open()
        } catch {
            // Native open itself cleans up all partially acquired resources.
            do { try await lease.release(); await ProcessGate.shared.release() }
            catch { throw BackendError.releaseUnverified }
            throw error
        }
        return BackendUSBTransport(driver: driver, lease: lease)
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
        let bytes = try await driver.read(maximumLength: maximumLength, timeoutMilliseconds: timeoutMilliseconds)
        guard !bytes.isEmpty, bytes.count <= maximumLength else { throw BackendError.transport }
        return bytes // fragments are valid, never pad or invent bytes
    }
    public func write(_ data: Data, timeoutMilliseconds: UInt32) async throws {
        try validate(data.count, timeoutMilliseconds)
        try begin()
        defer { active = false }
        // A driver success is a full transfer. Driver failures are not retried.
        try await driver.write(data, timeoutMilliseconds: timeoutMilliseconds)
    }
    public func close() async throws {
        guard !closed else { throw BackendError.unavailable }
        guard !active else { throw BackendError.busy }
        active = true
        defer { active = false }
        do { try await driver.close() }
        catch { closed = true; throw BackendError.releaseUnverified }
        closed = true
        do { try await lease.release(); await ProcessGate.shared.release() }
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
