import Foundation
import IOKit
import SwitchShelfDomain

public struct DeviceServiceError: Error, LocalizedError, Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable {
        case runtimeMissing, runtimeIncompatible, busy, noDevice, multipleDevices
        case accessDeniedOrBusy, transport, invalidMetadata, resourceLimit
    }
    public let code: Code
    public let message: String
    public let nativeCode: Int?
    public var errorDescription: String? { message }
    public init(code: Code, message: String, nativeCode: Int? = nil) {
        self.code = code; self.message = message; self.nativeCode = nativeCode
    }
}

/// No installation or file-transfer capability is exposed. Each inventory opens a new,
/// session-scoped identity and releases the USB session before returning.
public actor DeviceService {
    public init() {}

    /// USB descriptors are candidates only. Discovery never opens an MTP session or says ready.
    public func discover() async -> DeviceDiscovery {
        do { return DiscoveryClassifier.classify(try USBDiscovery.read()) }
        catch {
            return DeviceDiscovery(state: .error, message: "USB 枚举失败；请检查数据线、连接和应用权限。")
        }
    }

    public func readInventory() async throws -> InstalledInventory {
        try await read(storageDiagnosticsOnly: false)
    }

    /// Lists only storage descriptions, without enumerating any content objects.
    /// The returned inventory is intentionally incomplete and contains no records.
    public func readStorageDiagnostics() async throws -> InstalledInventory {
        try await read(storageDiagnosticsOnly: true)
    }

    private func read(storageDiagnosticsOnly: Bool) async throws -> InstalledInventory {
        try Task.checkCancellation()
        let runtime = RuntimeLocation.preferredPath()
        let inventory = try await InventoryCoordinator.shared.read(runtimePath: runtime,
            useLibmtp: ProcessInfo.processInfo.environment["SWITCHSHELF_MTP_TRANSPORT"] == "libmtp",
            storageDiagnosticsOnly: storageDiagnosticsOnly)
        try Task.checkCancellation()
        return inventory
    }
}

struct USBDescriptor: Sendable, Equatable {
    let vendorID: UInt16
    let productID: UInt16
    /// IOKit registry entry lifetime, never a persistent device identity.
    var registryID: UInt64? = nil
}

enum DiscoveryClassifier {
    static func classify(_ descriptors: [USBDescriptor]) -> DeviceDiscovery {
        let candidates = descriptors.filter {
            $0.vendorID == 0x057e && [UInt16(0x201d), UInt16(0x3000), UInt16(0x2000)].contains($0.productID)
        }
        let devices = candidates.map { candidate in
            let name: String
            switch candidate.productID {
            case 0x201d: name = "Switch MTP 候选设备"
            case 0x3000: name = "DBI Backend 候选设备"
            default: name = "Nintendo Switch USB 候选设备"
            }
            return DeviceDescriptor(id: candidate.registryID.map { "usb-registry-\($0)" } ?? "usb-observation-\(UUID().uuidString)", name: name,
                                    vendorID: candidate.vendorID, productID: candidate.productID)
        }
        if devices.isEmpty {
            return DeviceDiscovery(state: .disconnected, message: "未检测到 Switch USB 设备；请连接数据线，并开启 sphaira 的 MTP 或 DBI 的 Run MTP responder。")
        }
        if devices.count > 1 {
            return DeviceDiscovery(state: .detected, devices: devices, message: "检测到多个候选设备；只读清单目前要求仅连接一台目标设备，尚未验证 MTP。")
        }
        let message: String
        switch candidates[0].productID {
        case 0x201d:
            message = "已发现 Switch MTP 候选设备，尚未握手。请保持 sphaira 或 DBI 的 MTP 开启，再读取清单；USB 识别不代表可安装。"
        case 0x3000:
            message = "检测到 DBI Backend 候选设备；读取清单需要切换到 sphaira 或 DBI 的 MTP 模式，尚未验证通道。"
        default:
            message = "检测到 Nintendo Switch USB 候选设备，当前协议未确认；请开启 sphaira 或 DBI 的 MTP，不能据此读取清单或安装。"
        }
        return DeviceDiscovery(state: .waitingForMTP, devices: devices, message: message)
    }
}

private enum USBDiscovery {
    static func read() throws -> [USBDescriptor] {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard status == KERN_SUCCESS else {
            throw DeviceServiceError(code: .transport, message: "IOKit enumeration failed", nativeCode: Int(status))
        }
        defer { IOObjectRelease(iterator) }
        var result: [USBDescriptor] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            // Deliberately never read USB Serial Number, product strings or unrelated properties.
            func number(_ key: String) -> UInt16? {
                guard let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                      let value = property as? NSNumber,
                      value.int64Value >= 0, value.int64Value <= UInt16.max else { return nil }
                return value.uint16Value
            }
            guard let vendor = number("idVendor"), vendor == 0x057e,
                  let product = number("idProduct") else { continue }
            var registryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
                throw DeviceServiceError(code: .transport, message: "无法确认 USB 枚举会话。")
            }
            result.append(USBDescriptor(vendorID: vendor, productID: product, registryID: registryID))
        }
        return result
    }
}

enum RuntimeLocation {
    static func preferredPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["SWITCHSHELF_LIBMTP_PATH"], !override.isEmpty {
            return override
        }
        if let frameworks = Bundle.main.privateFrameworksURL {
            for name in ["libmtp.dylib", "libmtp.9.dylib"] {
                let path = frameworks.appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return nil // Bridge searches executable-relative Frameworks, then development locations.
    }
}
