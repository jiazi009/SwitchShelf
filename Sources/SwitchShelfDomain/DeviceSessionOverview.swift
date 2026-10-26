import Foundation

/// Read-only projection of one device session for the device page.
/// Values come only from the discovery and inventory already in memory.
/// Firmware, serial number, battery, nickname and Wi-Fi are unknown:
/// the inventory read does not retain them.
public struct DeviceSessionOverview: Equatable, Sendable {
    public enum Fact: Equatable, Sendable {
        case known(String)
        case unknown

        public var text: String {
            switch self {
            case .known(let value): value
            case .unknown: "未知"
            }
        }

        public var isKnown: Bool {
            if case .known = self { return true }
            return false
        }
    }

    public enum InventorySession: Equatable, Sendable {
        case unknown
        case current
        case previous

        public var text: String {
            switch self {
            case .unknown: "未知"
            case .current: "属于当前会话"
            case .previous: "不属于当前会话"
            }
        }
    }

    public enum Completeness: Equatable, Sendable {
        case unknown
        case complete
        case incomplete

        public var text: String {
            switch self {
            case .unknown: "未知"
            case .complete: "完整"
            case .incomplete: "不完整"
            }
        }
    }

    public enum StorageDiagnostics: Equatable, Sendable {
        case unknown
        case diagnosticsOnly
        case notDiagnosticsOnly

        public var text: String {
            switch self {
            case .unknown: "未知"
            case .diagnosticsOnly: "是"
            case .notDiagnosticsOnly: "否"
            }
        }
    }

    public enum USBListing: Equatable, Sendable {
        case unknown
        case none
        case devices([USBDeviceFact])
    }

    public struct USBDeviceFact: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var vendorID: UInt16
        public var productID: UInt16
    }

    public enum IssueListing: Equatable, Sendable {
        case unknown
        case none
        case listed([String])
    }

    public struct StorageEntry: Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var isInventoryEntry: Bool
        public var roleLabel: String
    }

    public struct StorageSection: Equatable, Sendable {
        public var available: Bool
        public var entries: [StorageEntry]
        public var reportedStorageCount: Int?
        public var namesTruncated: Bool
        public var omittedNameCount: Int
        public var diagnostics: StorageDiagnostics
        public var gameDirectoryCount: Int?
        public var metadataObjectCount: Int?
        /// Inventory-entry names that were not among the displayed storage names.
        public var entryNamesMissingFromList: [String]
        public var notes: [String]
    }

    public enum CatalogGrouping: Equatable, Sendable {
        case notRead
        case complete
        case incomplete
        case emptyRecognizedEntry
        case storageListWithoutGameEntry
        case storageDiagnosticsOnly
    }

    public struct ContentCatalog: Equatable, Sendable {
        public var grouping: CatalogGrouping
        public var title: String
        public var explanation: String
        public var recordCount: Int?
    }

    public var connectionLabel: String
    public var discoveryMessage: Fact
    public var usb: USBListing
    public var inventorySession: InventorySession
    public var observedAt: Date?
    public var environmentContext: Fact
    public var completeness: Completeness
    public var issues: IssueListing
    public var firmware: Fact
    public var serialNumber: Fact
    public var battery: Fact
    public var nickname: Fact
    public var wifiStatus: Fact
    public var storage: StorageSection
    public var catalog: ContentCatalog

    public static func make(
        discovery: DeviceDiscovery?,
        inventory: InstalledInventory?,
        inventoryBelongsToCurrentSession: Bool,
        isDiscovering: Bool = false,
        isReadingInventory: Bool = false
    ) -> DeviceSessionOverview {
        let connectionLabel = connectionLabel(
            discovery: discovery,
            isDiscovering: isDiscovering,
            isReadingInventory: isReadingInventory
        )
        let discoveryMessage = discoveryMessage(
            discovery: discovery,
            isDiscovering: isDiscovering
        )
        let usb = usbListing(discovery)
        let session: InventorySession
        if inventory == nil {
            session = .unknown
        } else if inventoryBelongsToCurrentSession {
            session = .current
        } else {
            session = .previous
        }
        let environment = environmentFact(inventory?.environmentContext)
        let completeness: Completeness
        let issues: IssueListing
        if let inventory {
            completeness = inventory.isComplete ? .complete : .incomplete
            issues = inventory.issues.isEmpty ? .none : .listed(inventory.issues)
        } else {
            completeness = .unknown
            issues = .unknown
        }
        let storage = storageSection(inventory?.mtpEvidence)
        let catalog = contentCatalog(inventory)
        return DeviceSessionOverview(
            connectionLabel: connectionLabel,
            discoveryMessage: discoveryMessage,
            usb: usb,
            inventorySession: session,
            observedAt: inventory?.observedAt,
            environmentContext: environment,
            completeness: completeness,
            issues: issues,
            firmware: .unknown,
            serialNumber: .unknown,
            battery: .unknown,
            nickname: .unknown,
            wifiStatus: .unknown,
            storage: storage,
            catalog: catalog
        )
    }

    public func summaryLines(observationTime: String) -> [String] {
        var lines = [
            "连接状态：\(connectionLabel)",
            "发现消息：\(discoveryMessage.text)",
            "清单会话：\(inventorySession.text)",
            "观察时间：\(observationTime)",
            "环境：\(environmentContext.text)",
            "清单完整性：\(completeness.text)",
            "固件：\(firmware.text)",
            "序列号：\(serialNumber.text)",
            "电量：\(battery.text)",
            "昵称：\(nickname.text)",
            "Wi-Fi：\(wifiStatus.text)"
        ]
        switch issues {
        case .unknown:
            lines.append("问题：未知")
        case .none:
            lines.append("问题：没有列出问题")
        case .listed(let items):
            lines.append("问题：")
            lines.append(contentsOf: items.map { " - \($0)" })
        }
        switch usb {
        case .unknown:
            lines.append("USB 设备：未知")
        case .none:
            lines.append("USB 设备：这次检测没有列出候选设备")
        case .devices(let devices):
            for device in devices {
                let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = name.isEmpty ? "未知" : name
                lines.append("USB：\(shown) VID \(Self.hex(device.vendorID)) PID \(Self.hex(device.productID))")
            }
        }
        if storage.available {
            lines.append("仅为存储诊断：\(storage.diagnostics.text)")
            lines.append("游戏目录数：\(storage.gameDirectoryCount.map(String.init) ?? "未知")")
            lines.append("元数据对象数：\(storage.metadataObjectCount.map(String.init) ?? "未知")")
            lines.append("回报存储项数：\(storage.reportedStorageCount.map(String.init) ?? "未知")")
            for entry in storage.entries {
                lines.append("存储：\(entry.name)（\(entry.roleLabel)）")
            }
            for name in storage.entryNamesMissingFromList {
                lines.append("清单入口未出现在已列出的存储名中：\(name)")
            }
            lines.append(contentsOf: storage.notes)
        } else {
            lines.append(contentsOf: storage.notes)
        }
        lines.append("内容目录：\(catalog.title)")
        lines.append(catalog.explanation)
        if let count = catalog.recordCount {
            lines.append("内容记录：\(count) 条")
        } else {
            lines.append("内容记录：未知")
        }
        return lines
    }

    private static func hex(_ value: UInt16) -> String {
        String(format: "0x%04X", value)
    }

    private static func connectionLabel(
        discovery: DeviceDiscovery?,
        isDiscovering: Bool,
        isReadingInventory: Bool
    ) -> String {
        if isDiscovering { return "正在检测 USB 设备" }
        if isReadingInventory { return "正在读取已安装清单" }
        guard let discovery else { return "尚未检测设备" }
        switch discovery.state {
        case .disconnected: return "未检测到设备"
        case .detected: return "已检测到 USB 设备"
        case .waitingForMTP: return "等待 MTP 响应"
        case .ready: return "MTP 已连接"
        case .reading: return "正在读取"
        case .busy: return "设备忙碌"
        case .error: return "连接错误"
        }
    }

    private static func discoveryMessage(discovery: DeviceDiscovery?, isDiscovering: Bool) -> Fact {
        if isDiscovering {
            return .known("正在通过 IOKit 执行只读 USB 枚举。")
        }
        guard let discovery else { return .unknown }
        let message = discovery.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? .unknown : .known(message)
    }

    private static func usbListing(_ discovery: DeviceDiscovery?) -> USBListing {
        guard let discovery else { return .unknown }
        if discovery.devices.isEmpty { return .none }
        return .devices(discovery.devices.map {
            USBDeviceFact(id: $0.id, name: $0.name, vendorID: $0.vendorID, productID: $0.productID)
        })
    }

    private static func environmentFact(_ value: String?) -> Fact {
        guard let value else { return .unknown }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .unknown : .known(trimmed)
    }

    private static func storageSection(_ evidence: MTPInventoryEvidence?) -> StorageSection {
        guard let evidence else {
            return StorageSection(
                available: false,
                entries: [],
                reportedStorageCount: nil,
                namesTruncated: false,
                omittedNameCount: 0,
                diagnostics: .unknown,
                gameDirectoryCount: nil,
                metadataObjectCount: nil,
                entryNamesMissingFromList: [],
                notes: ["这次会话没有存储证据。存储名称、清单入口、游戏目录数和元数据对象数都是未知。"]
            )
        }
        let names = evidence.reportedStorageNames
        let entries = names.enumerated().map { index, name in
            let isEntry = evidence.inventoryStorageNames.contains(name)
            let role: String
            if isEntry && evidence.storageDiagnosticsOnly {
                role = "清单入口，本次未读取内容"
            } else if isEntry {
                role = "清单入口"
            } else {
                role = "已回报"
            }
            return StorageEntry(id: "reported-\(index)", name: name, isInventoryEntry: isEntry, roleLabel: role)
        }
        let truncated = evidence.reportedStorageCount > names.count
        let omitted = truncated ? evidence.reportedStorageCount - names.count : 0
        let missing = evidence.inventoryStorageNames.filter { !names.contains($0) }
        var notes: [String] = []
        if evidence.storageDiagnosticsOnly {
            notes.append("本次没有遍历游戏入口。目录数和元数据对象数是诊断结果里的计数，不是已确认的空设备。")
        }
        if truncated {
            notes.append("已列出 \(names.count) 个存储名。设备回报了 \(evidence.reportedStorageCount) 项，其余 \(omitted) 个名称没有放进这次证据，保持未知。")
        }
        return StorageSection(
            available: true,
            entries: entries,
            reportedStorageCount: evidence.reportedStorageCount,
            namesTruncated: truncated,
            omittedNameCount: omitted,
            diagnostics: evidence.storageDiagnosticsOnly ? .diagnosticsOnly : .notDiagnosticsOnly,
            gameDirectoryCount: evidence.gameDirectoryCount,
            metadataObjectCount: evidence.metadataObjectCount,
            entryNamesMissingFromList: missing,
            notes: notes
        )
    }

    private static func contentCatalog(_ inventory: InstalledInventory?) -> ContentCatalog {
        guard let inventory else {
            return ContentCatalog(
                grouping: .notRead,
                title: "尚未读取",
                explanation: "还没有这次会话的内容目录。",
                recordCount: nil
            )
        }
        let evidence = inventory.mtpEvidence
        let hasRecords = !inventory.records.isEmpty
        if evidence?.storageDiagnosticsOnly == true {
            let noEntry = evidence?.inventoryStorageNames.isEmpty != false
            let explanation = noEntry
                ? "这次只枚举存储名称，没有读取游戏对象。已回报的名称里没有 Games 或 Installed games 入口。缺少入口不是未安装结论。"
                : "这次只枚举存储名称，没有读取游戏入口里的对象。已识别的入口名称不代表入口为空，也不是未安装结论。"
            return ContentCatalog(
                grouping: .storageDiagnosticsOnly,
                title: "仅为存储诊断",
                explanation: explanation,
                recordCount: inventory.records.count
            )
        }
        if let evidence, evidence.inventoryStorageNames.isEmpty {
            if evidence.reportedStorageCount > 0 || !evidence.reportedStorageNames.isEmpty {
                return ContentCatalog(
                    grouping: .storageListWithoutGameEntry,
                    title: "有存储列表，没有游戏入口",
                    explanation: "这次会话回报了存储名称，但没有 Games 或 Installed games 入口。缺少入口不是未安装结论。",
                    recordCount: inventory.records.count
                )
            }
            return ContentCatalog(
                grouping: .incomplete,
                title: "清单不完整",
                explanation: "存储枚举没有回报名称，也没有游戏入口。这不是未安装结论。",
                recordCount: inventory.records.count
            )
        }
        if let evidence, !evidence.inventoryStorageNames.isEmpty, !hasRecords, inventory.isComplete {
            return ContentCatalog(
                grouping: .emptyRecognizedEntry,
                title: "已识别入口为空",
                explanation: "已识别的游戏入口返回空记录，且清单标记为完整。这只表示该入口没有内容记录，不是设备未安装的结论。",
                recordCount: 0
            )
        }
        if inventory.isComplete {
            if hasRecords {
                return ContentCatalog(
                    grouping: .complete,
                    title: "清单完整",
                    explanation: "清单完整。下面是这次会话读到的内容记录。",
                    recordCount: inventory.records.count
                )
            }
            return ContentCatalog(
                grouping: .complete,
                title: "清单完整",
                explanation: "清单标记为完整，但没有内容记录，也没有可展示的存储入口证据。缺少记录不是未安装结论。",
                recordCount: 0
            )
        }
        if let evidence, !evidence.inventoryStorageNames.isEmpty, !hasRecords {
            return ContentCatalog(
                grouping: .incomplete,
                title: "清单不完整",
                explanation: "已识别游戏入口，但清单不完整，没有可展示的记录。不能把缺少记录当成入口为空或未安装结论。",
                recordCount: 0
            )
        }
        if hasRecords {
            return ContentCatalog(
                grouping: .incomplete,
                title: "清单不完整",
                explanation: "清单不完整。下面只列出已经读到的记录，其余覆盖范围未知。",
                recordCount: inventory.records.count
            )
        }
        return ContentCatalog(
            grouping: .incomplete,
            title: "清单不完整",
            explanation: "清单不完整，没有可展示的记录，也没有这次会话的存储证据。不能据此得出未安装结论。",
            recordCount: 0
        )
    }
}
