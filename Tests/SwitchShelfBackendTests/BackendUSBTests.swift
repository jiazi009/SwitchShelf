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
private actor FakeDriver: BackendUSBDriver {
    var opens = 0
    var writes: [Data] = []
    var failClose = false
    var failWrite = false
    var readBytes = Data([1, 2])
    func open() { opens += 1 }
    func read(maximumLength: Int, timeoutMilliseconds: UInt32) -> Data { readBytes }
    func write(_ data: Data, timeoutMilliseconds: UInt32) throws {
        writes.append(data)
        if failWrite { throw BackendError.transport }
    }
    func close() throws { if failClose { throw BackendError.releaseUnverified } }
    func setFailures(write: Bool = false, close: Bool = false) { failWrite=write; failClose=close }
    func counts() -> (Int, Int) { (opens, writes.count) }
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
    try await stream.write(Data([3,4]), timeoutMilliseconds: 100)
    #expect(await driver.counts().1 == 1)
    try await stream.close()
    #expect(await lease.counts().1 == 1)
    await #expect(throws: BackendError.unavailable) { try await stream.close() }

    let secondLease=FakeLease(), secondDriver=FakeDriver()
    let secondStream=try await BackendUSBTransport.open(lease: secondLease, driver: secondDriver)
    await #expect(throws: BackendError.busy) { _ = try await BackendUSBTransport.open(lease: FakeLease(), driver: FakeDriver()) }
    await secondDriver.setFailures(write: true, close: true)
    await #expect(throws: BackendError.transport) { try await secondStream.write(Data([1]), timeoutMilliseconds: 20) }
    #expect(await secondDriver.counts().1 == 1) // uncertain write never retried
    await #expect(throws: BackendError.releaseUnverified) { try await secondStream.close() }
    #expect(await secondLease.counts().1 == 0)
    await #expect(throws: BackendError.busy) { _ = try await BackendUSBTransport.open(lease: FakeLease(), driver: FakeDriver()) }
}
