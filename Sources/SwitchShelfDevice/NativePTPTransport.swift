import Foundation
@preconcurrency import ImageCaptureCore
import SwitchShelfDomain

/// Uses the system ImageCapture broker rather than competing with ptpcamerad for USB.
/// The browser and camera objects never leave MainActor. Only Sendable metadata does.
@MainActor
final class NativePTPTransport: NSObject, @preconcurrency ICDeviceBrowserDelegate, InventoryTransport {
    private let browser = ICDeviceBrowser()
    private var candidates: [ICCameraDevice] = []
    private var camera: ICCameraDevice?
    private var discovery: CheckedContinuation<Void, any Error>?
    private var transaction: UInt32 = 0
    private var opened = false
    private var removed = false

    static func connect() async throws -> NativePTPTransport {
        let transport = NativePTPTransport()
        do {
            try await transport.findDevice()
            try await transport.open()
            return transport
        } catch {
            try? await transport.close()
            throw error
        }
    }
    private func findDevice() async throws {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        try await withCheckedThrowingContinuation { continuation in
            discovery = continuation
            browser.start()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, let continuation = self.discovery else { return }
                self.discovery = nil
                guard self.candidates.count == 1 else {
                    continuation.resume(throwing: DeviceServiceError(
                        code: self.candidates.isEmpty ? .noDevice : .multipleDevices,
                        message: self.candidates.isEmpty
                            ? "ImageCaptureCore 未发现可访问的 057e:201d MTP 候选设备；请停留在 DBI Run MTP responder 并检查连接/应用权限。"
                            : "发现多个 MTP 候选设备；只读清单要求一台活动目标设备。"))
                    return
                }
                self.camera = self.candidates[0]
                continuation.resume()
            }
        }
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard device.usbVendorID == 0x057e, device.usbProductID == 0x201d,
              let camera = device as? ICCameraDevice,
              !candidates.contains(where: { $0 === camera }) else { return }
        candidates.append(camera)
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        candidates.removeAll { $0 === device }
        if camera === device { removed = true }
    }
    private func open() async throws {
        guard let camera, camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else {
            throw DeviceServiceError(code: .transport, message: "候选设备未提供 PTP 命令能力；尚未验证 DBI MTP。")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            camera.requestOpenSession(options: nil) { error in
                if let error {
                    continuation.resume(throwing: DeviceServiceError(code: .accessDeniedOrBusy,
                        message: "系统 MTP 会话无法打开；请关闭用户启动的其他客户端、确认权限和 DBI 模式，不要修改系统相机设置。",
                        nativeCode: (error as NSError).code))
                } else { continuation.resume() }
            }
        }
        opened = true
    }
    func close() async throws {
        defer {
            browser.stop(); browser.delegate = nil
            candidates.removeAll(); camera = nil; opened = false; removed = false
        }
        guard opened, let camera else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            camera.requestCloseSession(options: nil) { error in
                if let error {
                    continuation.resume(throwing: DeviceServiceError(code: .transport,
                        message: "系统 MTP 会话关闭失败；当前清单不能视为完整，请重新连接后核对。", nativeCode: (error as NSError).code))
                } else { continuation.resume() }
            }
        }
    }
    private func send(_ operation: UInt16, _ parameters: [UInt32] = []) async throws -> Data {
        try Task.checkCancellation()
        guard opened, !removed, let camera else { throw DeviceServiceError(code: .transport, message: "系统 MTP 会话已断开。") }
        transaction &+= 1
        let command = try PTPCodec.command(operation, parameters: parameters, transaction: transaction)
        return try await withCheckedThrowingContinuation { continuation in
            camera.requestSendPTPCommand(command, outData: nil) { data, response, error in
                do {
                    if let error {
                        throw DeviceServiceError(code: .transport, message: "系统 MTP 元数据请求失败，清单覆盖范围未知。", nativeCode: (error as NSError).code)
                    }
                    try PTPCodec.validateResponse(response)
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func storages() async throws -> [MTPStorage] {
        let ids = try PTPCodec.identifiers(await send(0x1004))
        var storages: [MTPStorage] = []
        for id in ids {
            storages.append(try PTPCodec.storage(await send(0x1005, [id]), id: id))
        }
        return storages
    }
    func children(storage: UInt32, parent: UInt32) async throws -> [UInt32] {
        try PTPCodec.identifiers(await send(0x1007, [storage, 0, parent]))
    }
    func object(id: UInt32) async throws -> MTPObject {
        try PTPCodec.object(await send(0x1008, [id]), id: id)
    }
}

/// A reentrancy gate holds across awaits, across transports, and across all public services.
actor InventoryCoordinator {
    static let shared = InventoryCoordinator()
    private var busy = false
    func read(runtimePath: String?, useLibmtp: Bool, storageDiagnosticsOnly: Bool = false) async throws -> InstalledInventory {
        guard !busy else { throw DeviceServiceError(code: .busy, message: "只读清单会话正在进行；请等待完成。") }
        busy = true
        defer { busy = false }
        let transport: any InventoryTransport
        if useLibmtp { transport = try NativeMTPSession(runtimePath: runtimePath) }
        else { transport = try await NativePTPTransport.connect() }
        do {
            var inventory = try await InventoryReader().read(from: transport, storageDiagnosticsOnly: storageDiagnosticsOnly)
            do { try await transport.close() }
            catch {
                inventory.isComplete = false
                inventory.issues.append("MTP session release failed; reconnect and verify before relying on this snapshot.")
            }
            return inventory
        } catch {
            try? await transport.close()
            throw error
        }
    }
}
