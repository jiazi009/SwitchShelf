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
        try Task.checkCancellation()
        let runtime = RuntimeLocation.preferredPath()
        let inventory = try await InventoryCoordinator.shared.read(runtimePath: runtime,
            useLibmtp: ProcessInfo.processInfo.environment["SWITCHSHELF_MTP_TRANSPORT"] == "libmtp")
        try Task.checkCancellation()
        return inventory
    }
}

struct USBDescriptor: Sendable, Equatable {
    let vendorID: UInt16
    let productID: UInt16
}

enum DiscoveryClassifier {
    static func classify(_ descriptors: [USBDescriptor]) -> DeviceDiscovery {
        let candidates = descriptors.filter {
            $0.vendorID == 0x057e && [UInt16(0x201d), UInt16(0x3000)].contains($0.productID)
        }
        let devices = candidates.map {
            DeviceDescriptor(id: "usb-observation-\(UUID().uuidString)",
                             name: $0.productID == 0x201d ? "Switch MTP 候选设备" : "DBI Backend 候选设备",
                             vendorID: $0.vendorID, productID: $0.productID)
        }
        if devices.isEmpty {
            return DeviceDiscovery(state: .disconnected, message: "未检测到受支持的 Switch/DBI USB 描述符；请连接数据线并打开 DBI → Run MTP responder。")
        }
        if devices.count > 1 {
            return DeviceDiscovery(state: .detected, devices: devices, message: "检测到多个候选设备；只读清单目前要求仅连接一台目标设备，尚未验证 MTP。")
        }
        return DeviceDiscovery(state: .waitingForMTP, devices: devices,
            message: candidates[0].productID == 0x201d
                ? "检测到 057e:201d MTP 候选描述符，尚未握手；请停留在 DBI Run MTP responder，再读取清单。USB 识别不代表可安装。"
                : "检测到 057e:3000 Backend 候选描述符；读取清单需要手动进入 DBI → Run MTP responder，尚未验证通道。")
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
            result.append(USBDescriptor(vendorID: vendor, productID: product))
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
