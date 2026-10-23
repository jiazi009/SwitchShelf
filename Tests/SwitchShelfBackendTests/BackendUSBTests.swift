import Foundation
import Testing
@testable import SwitchShelfBackend
import CDBIBackendUSB

private actor FakeLease: BackendUSBDeviceLease {
    private var acquired = 0
    private var released = 0
    private var acquireFailure: BackendError?
    private var releaseFailure: BackendError?
    func configure(acquire: BackendError? = nil, release: BackendError? = nil) {
        acquireFailure = acquire; releaseFailure = release
    }
    func acquire() throws {
        acquired += 1
        if let acquireFailure { throw acquireFailure }
    }
    func release() throws {
        released += 1
        if let releaseFailure { throw releaseFailure }
    }
    func counts() -> (acquire: Int, release: Int) { (acquired, released) }
}

private actor DelayGate {
    private var entered: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private var didEnter = false
    func pause() async {
        didEnter = true
        entered?.resume(); entered = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entered = $0 }
    }
    func resume() { waiting?.resume(); waiting = nil }
}

private actor FakeDriver: BackendUSBDriver {
    private var opens = 0
    private var closes = 0
    private var writes = 0
    private var openFailure: BackendError?
    private var closeFailure: BackendError?
    private var writeFailure: BackendError?
    private var openDelay: DelayGate?
    private var readDelay: DelayGate?
    private var writeDelay: DelayGate?
    private var readBytes = Data([1, 2])
    func configure(openFailure: BackendError? = nil, closeFailure: BackendError? = nil,
                   writeFailure: BackendError? = nil, openDelay: DelayGate? = nil,
                   readDelay: DelayGate? = nil, writeDelay: DelayGate? = nil,
                   readBytes: Data = Data([1, 2])) {
        self.openFailure = openFailure; self.closeFailure = closeFailure
        self.writeFailure = writeFailure; self.openDelay = openDelay
        self.readDelay = readDelay; self.writeDelay = writeDelay
        self.readBytes = readBytes
    }
    func open() async throws {
        opens += 1
        if let openDelay { await openDelay.pause() }
        if let openFailure { throw openFailure }
    }
    func read(maximumLength: Int, timeoutMilliseconds: UInt32) async -> Data {
        if let readDelay { await readDelay.pause() }
        return readBytes
    }
    func write(_ data: Data, timeoutMilliseconds: UInt32) async throws {
        if let writeDelay { await writeDelay.pause() }
        writes += 1
        if let writeFailure { throw writeFailure }
    }
    func close() throws {
        closes += 1
        if let closeFailure { throw closeFailure }
    }
    func counts() -> (open: Int, close: Int, write: Int) { (opens, closes, writes) }
}

private func open(_ gate: BackendUSBProcessGate, _ lease: FakeLease, _ driver: FakeDriver) async throws -> BackendUSBTransport {
    try await BackendUSBTransport.open(lease: lease, driver: driver, gate: gate)
}

@Test func backendUSBDescriptorPredicateAndInvalidHandles() {
    #expect(ss_usb_is_backend(0x057e, 0x3000, 0xff, 0, 2, 1, 2, 0x81, 2) == 1)
    #expect(ss_usb_is_backend(0x057e, 0x201d, 0xff, 0, 2, 1, 2, 0x81, 2) == 0)
    #expect(ss_usb_is_backend(0x057e, 0x3000, 8, 0, 2, 1, 2, 0x81, 2) == 0)
    #expect(ss_usb_is_backend(0x057e, 0x3000, 0xff, 0, 2, 2, 2, 0x81, 2) == 0)
    #expect(ss_usb_is_backend(0x057e, 0x3000, 0xff, 0, 3, 1, 2, 0x81, 2) == 0)
    var length: UInt32 = 1
    var native: Int32 = 0
    #expect(ss_usb_read(nil, nil, &length, 1, &native) == SS_USB_INVALID)
    #expect(ss_usb_write(nil, nil, 1, 1, &native) == SS_USB_INVALID)
    #expect(ss_usb_close(nil, &native) == SS_USB_INVALID)
}

@Test func backendUSBValidationFragmentsAndWriteFailure() async throws {
    let gate=BackendUSBProcessGate(), lease=FakeLease(), driver=FakeDriver()
    let stream=try await open(gate, lease, driver)
    #expect(try await stream.read(maximumLength: 32, timeoutMilliseconds: 500) == Data([1,2]))
    await #expect(throws: BackendError.invalidPlan) { _ = try await stream.read(maximumLength: 0, timeoutMilliseconds: 10) }
    await #expect(throws: BackendError.invalidPlan) { _ = try await stream.read(maximumLength: 1_048_577, timeoutMilliseconds: 10) }
    await #expect(throws: BackendError.invalidPlan) { _ = try await stream.read(maximumLength: 1, timeoutMilliseconds: 60_001) }
    await #expect(throws: BackendError.invalidPlan) { try await stream.write(Data(), timeoutMilliseconds: 1) }
    await #expect(throws: BackendError.invalidPlan) { try await stream.write(Data([1]), timeoutMilliseconds: 0) }
    await driver.configure(readBytes: Data([1,2,3]))
    await #expect(throws: BackendError.transport) { _ = try await stream.read(maximumLength: 2, timeoutMilliseconds: 100) }
    await driver.configure(writeFailure: .transport)
    await #expect(throws: BackendError.transport) { try await stream.write(Data([3]), timeoutMilliseconds: 100) }
    #expect(await driver.counts().write == 1) // uncertain write is never retried
    await driver.configure()
    try await stream.write(Data([3,4]), timeoutMilliseconds: 100)
    try await stream.close()
    #expect(await lease.counts().release == 1)
    await #expect(throws: BackendError.unavailable) { try await stream.close() }
    let next=try await open(gate, FakeLease(), FakeDriver())
    try await next.close()
}

@Test func backendUSBNativeCloseFailurePermanentlyFencesGate() async throws {
    let gate=BackendUSBProcessGate(), lease=FakeLease(), driver=FakeDriver()
    await driver.configure(closeFailure: .transport)
    let stream=try await open(gate, lease, driver)
    await #expect(throws: BackendError.releaseUnverified) { try await stream.close() }
    #expect(await driver.counts().close == 1)
    #expect(await lease.counts().release == 0)
    await #expect(throws: BackendError.unavailable) { try await stream.close() }
    #expect(await driver.counts().close == 1) // no retry of uncertain close
    await #expect(throws: BackendError.busy) { _ = try await open(gate, FakeLease(), FakeDriver()) }
}

@Test func backendUSBLeaseReleaseFailurePermanentlyFencesGate() async throws {
    let gate=BackendUSBProcessGate(), lease=FakeLease(), driver=FakeDriver()
    await lease.configure(release: .transport)
    let stream=try await open(gate, lease, driver)
    await #expect(throws: BackendError.releaseUnverified) { try await stream.close() }
    #expect(await driver.counts().close == 1)
    #expect(await lease.counts().release == 1)
    await #expect(throws: BackendError.unavailable) { try await stream.close() }
    #expect(await lease.counts().release == 1) // no retry of uncertain release
    await #expect(throws: BackendError.busy) { _ = try await open(gate, FakeLease(), FakeDriver()) }
}

@Test func backendUSBUncertainNativeOpenRetainsBothGates() async throws {
    let gate=BackendUSBProcessGate(), lease=FakeLease(), driver=FakeDriver()
    await driver.configure(openFailure: .releaseUnverified)
    await #expect(throws: BackendError.releaseUnverified) { _ = try await open(gate, lease, driver) }
    #expect(await lease.counts().release == 0)
    #expect(await driver.counts().close == 0) // do not blindly close uncertain open
    await #expect(throws: BackendError.busy) { _ = try await open(gate, FakeLease(), FakeDriver()) }
}

@Test func backendUSBKnownOpenFailureCleansUp() async throws {
    let gate=BackendUSBProcessGate(), lease=FakeLease(), driver=FakeDriver()
    await driver.configure(openFailure: .unavailable)
    await #expect(throws: BackendError.unavailable) { _ = try await open(gate, lease, driver) }
    #expect(await lease.counts().release == 1)
    #expect(await driver.counts().close == 0)
    let next=try await open(gate, FakeLease(), FakeDriver())
    try await next.close()
}

@Test func backendUSBKnownAndUncertainLeaseAcquireFailures() async throws {
    let knownGate=BackendUSBProcessGate(), knownLease=FakeLease(), knownDriver=FakeDriver()
    await knownLease.configure(acquire: .busy)
    await #expect(throws: BackendError.busy) { _ = try await open(knownGate, knownLease, knownDriver) }
    #expect(await knownDriver.counts().open == 0)
    let next=try await open(knownGate, FakeLease(), FakeDriver())
    try await next.close()

    let uncertainGate=BackendUSBProcessGate(), uncertainLease=FakeLease(), uncertainDriver=FakeDriver()
    await uncertainLease.configure(acquire: .releaseUnverified)
    await #expect(throws: BackendError.releaseUnverified) { _ = try await open(uncertainGate, uncertainLease, uncertainDriver) }
    #expect(await uncertainLease.counts().release == 0)
    #expect(await uncertainDriver.counts().open == 0)
    await #expect(throws: BackendError.busy) { _ = try await open(uncertainGate, FakeLease(), FakeDriver()) }
}

@Test func backendUSBCancellationBeforeAndDuringOpen() async throws {
    let gate=BackendUSBProcessGate(), cancelledLease=FakeLease(), cancelledDriver=FakeDriver()
    let cancelled=Task { () throws -> BackendUSBTransport in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await open(gate, cancelledLease, cancelledDriver)
    }
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(await cancelledLease.counts().acquire == 0)
    #expect(await cancelledDriver.counts().open == 0)

    let openDelay=DelayGate(), lease=FakeLease(), driver=FakeDriver()
    await driver.configure(openDelay: openDelay)
    let opening=Task { try await open(gate, lease, driver) }
    await openDelay.waitUntilEntered()
    opening.cancel()
    #expect(await lease.counts().release == 0)
    await #expect(throws: BackendError.busy) { _ = try await open(gate, FakeLease(), FakeDriver()) }
    await openDelay.resume()
    await #expect(throws: BackendError.cancelled) { _ = try await opening.value }
    #expect(await driver.counts().close == 1)
    #expect(await lease.counts().release == 1)
    let next=try await open(gate, FakeLease(), FakeDriver())
    try await next.close()
}

@Test func backendUSBCancellationDuringIOBlocksCloseUntilCompletion() async throws {
    let gate=BackendUSBProcessGate(), lease=FakeLease(), driver=FakeDriver()
    let readDelay=DelayGate(), writeDelay=DelayGate()
    await driver.configure(readDelay: readDelay, writeDelay: writeDelay)
    let stream=try await open(gate, lease, driver)
    let reading=Task { try await stream.read(maximumLength: 8, timeoutMilliseconds: 100) }
    await readDelay.waitUntilEntered()
    reading.cancel()
    await #expect(throws: BackendError.busy) { try await stream.close() }
    #expect(await lease.counts().release == 0)
    await readDelay.resume()
    await #expect(throws: CancellationError.self) { _ = try await reading.value }
    let writing=Task { try await stream.write(Data([7]), timeoutMilliseconds: 100) }
    await writeDelay.waitUntilEntered()
    writing.cancel()
    await #expect(throws: BackendError.busy) { try await stream.close() }
    #expect(await lease.counts().release == 0)
    await writeDelay.resume()
    await #expect(throws: CancellationError.self) { try await writing.value }
    #expect(await driver.counts().write == 1)
    try await stream.close()
    #expect(await lease.counts().release == 1)
}
