import Foundation
import Testing
import SwitchShelfBackend
import CDBIBackendUSB

private actor FakeLease: BackendUSBDeviceLease {
    var acquired = 0
    var released = 0
    func acquire() throws { acquired += 1 }
    func release() throws { released += 1 }
    func counts() -> (Int, Int) { (acquired, released) }
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
    var opens = 0
    var writes: [Data] = []
    var failClose = false
    var failWrite = false
    var readBytes = Data([1, 2])
    var openFailure: BackendError?
    var openDelay: DelayGate?
    var readDelay: DelayGate?
    var writeDelay: DelayGate?
    var closes = 0
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
        writes.append(data)
        if failWrite { throw BackendError.transport }
    }
    func close() throws { closes += 1; if failClose { throw BackendError.releaseUnverified } }
    func configure(openFailure: BackendError? = nil, openDelay: DelayGate? = nil,
                   readDelay: DelayGate? = nil, writeDelay: DelayGate? = nil) {
        self.openFailure=openFailure; self.openDelay=openDelay
        self.readDelay=readDelay; self.writeDelay=writeDelay
    }
    func setReadBytes(_ data: Data) { readBytes = data }
    func setFailures(write: Bool = false, close: Bool = false) { failWrite=write; failClose=close }
    func counts() -> (Int, Int, Int) { (opens, writes.count, closes) }
}

@Test func backendUSBDescriptorPredicate() {
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
@Test func backendUSBValidationFragmentsAndWholeWrite() async throws {
    let lease = FakeLease(), driver = FakeDriver()
    let stream = try await BackendUSBTransport.open(lease: lease, driver: driver)
    #expect(try await stream.read(maximumLength: 32, timeoutMilliseconds: 500) == Data([1,2]))
    await #expect(throws: BackendError.invalidPlan) { try await stream.read(maximumLength: 0, timeoutMilliseconds: 10) }
    await #expect(throws: BackendError.invalidPlan) { try await stream.read(maximumLength: 1_048_577, timeoutMilliseconds: 10) }
    await #expect(throws: BackendError.invalidPlan) { try await stream.write(Data([3]), timeoutMilliseconds: 0) }
    await #expect(throws: BackendError.invalidPlan) { try await stream.write(Data(), timeoutMilliseconds: 1) }
    await #expect(throws: BackendError.invalidPlan) { try await stream.read(maximumLength: 1, timeoutMilliseconds: 60_001) }
    await driver.setReadBytes(Data([1,2,3]))
    await #expect(throws: BackendError.transport) { _ = try await stream.read(maximumLength: 2, timeoutMilliseconds: 100) }
    try await stream.write(Data([3,4]), timeoutMilliseconds: 100)
    #expect(await driver.counts().1 == 1)
    try await stream.close()
    #expect(await lease.counts().1 == 1)
    await #expect(throws: BackendError.unavailable) { try await stream.close() }

    // Cancellation before acquisition never calls the supplied lease or driver.
    let cancelledLease=FakeLease(), cancelledDriver=FakeDriver()
    let cancelled=Task { () throws -> BackendUSBTransport in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await BackendUSBTransport.open(lease: cancelledLease, driver: cancelledDriver)
    }
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(await cancelledLease.counts().0 == 0)
    #expect(await cancelledDriver.counts().0 == 0)

    let openDelay=DelayGate(), delayedLease=FakeLease(), delayedDriver=FakeDriver()
    await delayedDriver.configure(openDelay: openDelay)
    let opening=Task { try await BackendUSBTransport.open(lease: delayedLease, driver: delayedDriver) }
    await openDelay.waitUntilEntered()
    opening.cancel()
    #expect(await delayedLease.counts().1 == 0) // native open still alive
    await #expect(throws: BackendError.busy) { _ = try await BackendUSBTransport.open(lease: FakeLease(), driver: FakeDriver()) }
    await openDelay.resume()
    await #expect(throws: BackendError.cancelled) { _ = try await opening.value }
    #expect(await delayedDriver.counts().2 == 1)
    #expect(await delayedLease.counts().1 == 1)

    let readDelay=DelayGate(), writeDelay=DelayGate(), secondLease=FakeLease(), secondDriver=FakeDriver()
    await secondDriver.configure(readDelay: readDelay, writeDelay: writeDelay)
    let secondStream=try await BackendUSBTransport.open(lease: secondLease, driver: secondDriver)
    let reading=Task { try await secondStream.read(maximumLength: 8, timeoutMilliseconds: 100) }
    await readDelay.waitUntilEntered()
    reading.cancel()
    await #expect(throws: BackendError.busy) { try await secondStream.close() }
    await readDelay.resume()
    await #expect(throws: CancellationError.self) { _ = try await reading.value }
    let writing=Task { try await secondStream.write(Data([7]), timeoutMilliseconds: 100) }
    await writeDelay.waitUntilEntered()
    writing.cancel()
    await #expect(throws: BackendError.busy) { try await secondStream.close() }
    await writeDelay.resume()
    await #expect(throws: CancellationError.self) { try await writing.value }
    #expect(await secondDriver.counts().1 == 1) // no retry of cancelled write
    await secondDriver.configure()
    await secondDriver.setFailures(write: true)
    await #expect(throws: BackendError.transport) { try await secondStream.write(Data([8]), timeoutMilliseconds: 100) }
    #expect(await secondDriver.counts().1 == 2) // uncertain failure never retried
    try await secondStream.close()

    // An uncertain native open retains both gates and must not invoke close.
    let uncertainLease=FakeLease(), uncertainDriver=FakeDriver()
    await uncertainDriver.configure(openFailure: .releaseUnverified)
    await #expect(throws: BackendError.releaseUnverified) {
        _ = try await BackendUSBTransport.open(lease: uncertainLease, driver: uncertainDriver)
    }
    #expect(await uncertainLease.counts().1 == 0)
    #expect(await uncertainDriver.counts().2 == 0)
    await #expect(throws: BackendError.busy) { _ = try await BackendUSBTransport.open(lease: FakeLease(), driver: FakeDriver()) }
}
