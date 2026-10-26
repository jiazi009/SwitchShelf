import Foundation
import Testing
@testable import SwitchShelfDomain

@Suite("Device session overview")
struct DeviceSessionOverviewTests {
    private let observed = Date(timeIntervalSince1970: 1_700_000_000)

    private func device(_ name: String, vendor: UInt16, product: UInt16) -> DeviceDescriptor {
        DeviceDescriptor(id: "\(name)-\(vendor)-\(product)", name: name, vendorID: vendor, productID: product)
    }

    private func record(_ name: String, path: String) -> InstalledRecord {
        InstalledRecord(
            id: path,
            titleID: "0100AAAABBBB0000",
            kind: .base,
            rawVersion: 0x00010000,
            name: name,
            objectPath: path
        )
    }

    private func evidence(
        count: Int? = nil,
        names: [String],
        entries: [String],
        directories: Int = 0,
        metadata: Int = 0,
        diagnosticsOnly: Bool = false
    ) -> MTPInventoryEvidence {
        MTPInventoryEvidence(
            reportedStorageCount: count ?? names.count,
            reportedStorageNames: names,
            inventoryStorageNames: entries,
            gameDirectoryCount: directories,
            metadataObjectCount: metadata,
            storageDiagnosticsOnly: diagnosticsOnly
        )
    }

    private func inventory(
        complete: Bool,
        records: [InstalledRecord] = [],
        issues: [String] = [],
        environment: String? = nil,
        evidence: MTPInventoryEvidence? = nil
    ) -> InstalledInventory {
        InstalledInventory(
            deviceID: "mtp-session-fixture",
            environmentContext: environment,
            observedAt: observed,
            isComplete: complete,
            records: records,
            issues: issues,
            mtpEvidence: evidence
        )
    }

    @Test("未检测时机器事实保持未知，内容目录不声称未安装")
    func nothingObserved() {
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: nil, inventoryBelongsToCurrentSession: false)
        #expect(overview.connectionLabel == "尚未检测设备")
        #expect(overview.discoveryMessage == .unknown)
        #expect(overview.usb == .unknown)
        #expect(overview.inventorySession == .unknown)
        #expect(overview.observedAt == nil)
        #expect(overview.environmentContext == .unknown)
        #expect(overview.completeness == .unknown)
        #expect(overview.issues == .unknown)
        #expect(overview.firmware == .unknown)
        #expect(overview.serialNumber == .unknown)
        #expect(overview.battery == .unknown)
        #expect(overview.nickname == .unknown)
        #expect(overview.wifiStatus == .unknown)
        #expect(overview.storage.available == false)
        #expect(overview.storage.gameDirectoryCount == nil)
        #expect(overview.storage.metadataObjectCount == nil)
        #expect(overview.catalog.grouping == .notRead)
        #expect(overview.catalog.recordCount == nil)
        #expect(!overview.catalog.explanation.contains("未安装"))
        let lines = overview.summaryLines(observationTime: "未知")
        #expect(lines.contains("固件：未知"))
        #expect(lines.contains("序列号：未知"))
        #expect(lines.contains("电量：未知"))
        #expect(lines.contains("昵称：未知"))
        #expect(lines.contains("Wi-Fi：未知"))
        #expect(lines.contains("USB 设备：未知"))
        #expect(lines.contains("内容记录：未知"))
    }

    @Test("USB 候选只保留名称和 VID/PID，不把它们写成固件或昵称")
    func usbCandidatesStayDescriptors() {
        let discovery = DeviceDiscovery(
            state: .waitingForMTP,
            devices: [
                device("Switch MTP 候选设备", vendor: 0x057e, product: 0x201d),
                device("DBI Backend 候选设备", vendor: 0x057e, product: 0x3000)
            ],
            message: "检测到多个候选设备；只读清单目前要求仅连接一台目标设备，尚未验证 MTP。"
        )
        let overview = DeviceSessionOverview.make(discovery: discovery, inventory: nil, inventoryBelongsToCurrentSession: true)
        #expect(overview.connectionLabel == "等待 MTP 响应")
        #expect(overview.discoveryMessage == .known(discovery.message))
        #expect(overview.inventorySession == .unknown)
        guard case .devices(let devices) = overview.usb else {
            Issue.record("Expected both USB candidates")
            return
        }
        #expect(devices.map(\.name) == ["Switch MTP 候选设备", "DBI Backend 候选设备"])
        #expect(devices.map(\.vendorID) == [0x057e, 0x057e])
        #expect(devices.map(\.productID) == [0x201d, 0x3000])
        #expect(overview.nickname == .unknown)
        #expect(overview.firmware == .unknown)
        #expect(overview.catalog.grouping == .notRead)
        let lines = overview.summaryLines(observationTime: "未知")
        #expect(lines.contains("USB：Switch MTP 候选设备 VID 0x057E PID 0x201D"))
        #expect(lines.contains("USB：DBI Backend 候选设备 VID 0x057E PID 0x3000"))
    }

    @Test("检测进行中使用枚举提示，不把空白发现消息当成设备事实")
    func discoveringAndBlankMessage() {
        let blank = DeviceDiscovery(state: .disconnected, devices: [], message: "   ")
        let discovering = DeviceSessionOverview.make(
            discovery: blank, inventory: nil, inventoryBelongsToCurrentSession: false, isDiscovering: true
        )
        #expect(discovering.connectionLabel == "正在检测 USB 设备")
        #expect(discovering.discoveryMessage == .known("正在通过 IOKit 执行只读 USB 枚举。"))
        #expect(discovering.usb == .none)

        let idle = DeviceSessionOverview.make(discovery: blank, inventory: nil, inventoryBelongsToCurrentSession: false)
        #expect(idle.connectionLabel == "未检测到设备")
        #expect(idle.discoveryMessage == .unknown)
        #expect(idle.usb == .none)
        #expect(idle.summaryLines(observationTime: "未知").contains("USB 设备：这次检测没有列出候选设备"))
    }

    @Test("完整清单展示当前会话、环境和已识别入口，控制台字段仍未知")
    func completeCurrentSession() {
        let stored = evidence(
            names: ["Games", "microSD card", "Album", "Mounts", "Contents"],
            entries: ["Games"],
            directories: 10,
            metadata: 29
        )
        let records = [record("Game [0100AAAABBBB0000][v65536][BASE].nsp", path: "Games/Game/base.nsp")]
        let value = inventory(
            complete: true,
            records: records,
            environment: "  sphaira MTP  ",
            evidence: stored
        )
        let overview = DeviceSessionOverview.make(
            discovery: DeviceDiscovery(state: .ready, devices: [device("Switch MTP 候选设备", vendor: 0x057e, product: 0x201d)], message: "MTP 已连接 · Games"),
            inventory: value,
            inventoryBelongsToCurrentSession: true
        )
        #expect(overview.connectionLabel == "MTP 已连接")
        #expect(overview.inventorySession == .current)
        #expect(overview.observedAt == observed)
        #expect(overview.environmentContext == .known("sphaira MTP"))
        #expect(overview.completeness == .complete)
        #expect(overview.issues == .none)
        #expect(overview.firmware == .unknown)
        #expect(overview.serialNumber == .unknown)
        #expect(overview.battery == .unknown)
        #expect(overview.nickname == .unknown)
        #expect(overview.wifiStatus == .unknown)
        #expect(overview.storage.diagnostics == .notDiagnosticsOnly)
        #expect(overview.storage.gameDirectoryCount == 10)
        #expect(overview.storage.metadataObjectCount == 29)
        #expect(overview.storage.reportedStorageCount == 5)
        #expect(overview.storage.namesTruncated == false)
        #expect(overview.storage.entries.map(\.name) == ["Games", "microSD card", "Album", "Mounts", "Contents"])
        #expect(overview.storage.entries.map(\.roleLabel) == ["清单入口", "已回报", "已回报", "已回报", "已回报"])
        #expect(overview.storage.entryNamesMissingFromList.isEmpty)
        #expect(overview.catalog.grouping == .complete)
        #expect(overview.catalog.recordCount == 1)
        #expect(overview.catalog.explanation == "清单完整。下面是这次会话读到的内容记录。")
        let lines = overview.summaryLines(observationTime: "2023年11月15日 06:13")
        #expect(lines.contains("环境：sphaira MTP"))
        #expect(lines.contains("清单会话：属于当前会话"))
        #expect(lines.contains("仅为存储诊断：否"))
        #expect(lines.contains("游戏目录数：10"))
        #expect(lines.contains("元数据对象数：29"))
        #expect(lines.contains("存储：Games（清单入口）"))
        #expect(lines.contains("存储：microSD card（已回报）"))
        #expect(lines.contains("昵称：未知"))
        #expect(!lines.contains("未安装"))
    }

    @Test("不属于当前会话时仍展示已保留清单，但不把它写成这次握手")
    func previousSessionRemainsLabeled() {
        let value = inventory(
            complete: false,
            records: [record("partial.nsp", path: "Games/Game/partial.nsp")],
            issues: ["coverage is incomplete"],
            evidence: evidence(names: ["Games"], entries: ["Games"], directories: 1, metadata: 1)
        )
        let overview = DeviceSessionOverview.make(
            discovery: DeviceDiscovery(state: .waitingForMTP, devices: [device("Switch MTP 候选设备", vendor: 0x057e, product: 0x201d)], message: "已发现 USB 候选设备，本次 MTP 读取未成功"),
            inventory: value,
            inventoryBelongsToCurrentSession: false,
            isReadingInventory: true
        )
        #expect(overview.connectionLabel == "正在读取已安装清单")
        #expect(overview.inventorySession == .previous)
        #expect(overview.completeness == .incomplete)
        #expect(overview.issues == .listed(["coverage is incomplete"]))
        #expect(overview.catalog.grouping == .incomplete)
        #expect(overview.catalog.explanation == "清单不完整。下面只列出已经读到的记录，其余覆盖范围未知。")
        #expect(overview.catalog.recordCount == 1)
        #expect(!overview.catalog.explanation.contains("未安装"))
    }

    @Test("有存储名但没有游戏入口时列出全部名称，不说成未安装")
    func storageListWithoutGameEntry() {
        let names = ["DevNull", "Mounts", "Install", "Contents", "Album (Image SD)", "microSD card"]
        let value = inventory(
            complete: false,
            issues: ["MTP 已连接，但未提供可识别的游戏清单入口。"],
            evidence: evidence(names: names, entries: [])
        )
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: value, inventoryBelongsToCurrentSession: true)
        #expect(overview.catalog.grouping == .storageListWithoutGameEntry)
        #expect(overview.catalog.title == "有存储列表，没有游戏入口")
        #expect(overview.catalog.explanation == "这次会话回报了存储名称，但没有 Games 或 Installed games 入口。缺少入口不是未安装结论。")
        #expect(overview.storage.entries.map(\.name) == names)
        #expect(overview.storage.entries.allSatisfy { !$0.isInventoryEntry })
        #expect(overview.storage.gameDirectoryCount == 0)
        #expect(overview.storage.metadataObjectCount == 0)
        #expect(overview.storage.diagnostics == .notDiagnosticsOnly)
        #expect(overview.issues == .listed(["MTP 已连接，但未提供可识别的游戏清单入口。"]))
        #expect(overview.environmentContext == .unknown)
    }

    @Test("已识别入口且完整空记录单独分组，不说成未安装")
    func emptyRecognizedEntry() {
        let value = inventory(
            complete: true,
            evidence: evidence(names: ["Installed games", "SD Card"], entries: ["Installed games"])
        )
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: value, inventoryBelongsToCurrentSession: true)
        #expect(overview.catalog.grouping == .emptyRecognizedEntry)
        #expect(overview.completeness == .complete)
        #expect(overview.catalog.explanation == "已识别的游戏入口返回空记录，且清单标记为完整。这只表示该入口没有内容记录，不是设备未安装的结论。")
        #expect(overview.storage.entries.map(\.roleLabel) == ["清单入口", "已回报"])
        #expect(overview.catalog.recordCount == 0)
    }

    @Test("已识别入口但不完整时，不把缺少记录说成空入口")
    func recognizedEntryIncomplete() {
        let value = inventory(
            complete: false,
            issues: ["Inventory traversal exceeded its time budget; coverage is incomplete."],
            evidence: evidence(names: ["Games"], entries: ["Games"], directories: 2, metadata: 4)
        )
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: value, inventoryBelongsToCurrentSession: true)
        #expect(overview.catalog.grouping == .incomplete)
        #expect(overview.catalog.explanation == "已识别游戏入口，但清单不完整，没有可展示的记录。不能把缺少记录当成入口为空或未安装结论。")
        #expect(overview.storage.gameDirectoryCount == 2)
        #expect(overview.storage.metadataObjectCount == 4)
    }

    @Test("存储诊断即使认出 Games 也不当成空清单或未安装")
    func diagnosticsOnlyKeepsRecognizedNameUnread() {
        let value = inventory(
            complete: false,
            issues: ["本次仅枚举 MTP 存储名称，未遍历任何内容对象，不构成已安装清单。"],
            evidence: evidence(
                names: ["Games", "Mounts", "Contents"],
                entries: ["Games"],
                diagnosticsOnly: true
            )
        )
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: value, inventoryBelongsToCurrentSession: true)
        #expect(overview.catalog.grouping == .storageDiagnosticsOnly)
        #expect(overview.storage.diagnostics == .diagnosticsOnly)
        #expect(overview.storage.gameDirectoryCount == 0)
        #expect(overview.storage.metadataObjectCount == 0)
        #expect(overview.storage.entries.first?.roleLabel == "清单入口，本次未读取内容")
        #expect(overview.catalog.explanation == "这次只枚举存储名称，没有读取游戏入口里的对象。已识别的入口名称不代表入口为空，也不是未安装结论。")
        #expect(overview.storage.notes.contains("本次没有遍历游戏入口。目录数和元数据对象数是诊断结果里的计数，不是已确认的空设备。"))
    }

    @Test("只有存储诊断且没有游戏入口时同时说明两件事")
    func diagnosticsWithoutGameEntry() {
        let value = inventory(
            complete: false,
            evidence: evidence(names: ["Mounts", "Album"], entries: [], diagnosticsOnly: true)
        )
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: value, inventoryBelongsToCurrentSession: true)
        #expect(overview.catalog.grouping == .storageDiagnosticsOnly)
        #expect(overview.catalog.explanation == "这次只枚举存储名称，没有读取游戏对象。已回报的名称里没有 Games 或 Installed games 入口。缺少入口不是未安装结论。")
        #expect(overview.storage.entries.allSatisfy { !$0.isInventoryEntry })
    }

    @Test("被截断的存储名不补写，落在名单外的入口单独标出")
    func truncatedNamesStayUnknown() {
        let names = (1...32).map { "Storage \($0)" }
        let value = inventory(
            complete: false,
            evidence: evidence(count: 100, names: names, entries: ["Games"], directories: 0, metadata: 0)
        )
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: value, inventoryBelongsToCurrentSession: true)
        #expect(overview.storage.entries.count == 32)
        #expect(overview.storage.reportedStorageCount == 100)
        #expect(overview.storage.namesTruncated == true)
        #expect(overview.storage.omittedNameCount == 68)
        #expect(overview.storage.entryNamesMissingFromList == ["Games"])
        #expect(!overview.storage.entries.contains { $0.name == "Games" })
        #expect(overview.storage.notes.contains("已列出 32 个存储名。设备回报了 100 项，其余 68 个名称没有放进这次证据，保持未知。"))
        #expect(overview.catalog.grouping == .incomplete)
    }

    @Test("枚举结果没有任何存储名时不编造存储列表")
    func zeroStoragesAreNotAStorageList() {
        let value = inventory(
            complete: false,
            evidence: evidence(count: 0, names: [], entries: [])
        )
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: value, inventoryBelongsToCurrentSession: true)
        #expect(overview.catalog.grouping == .incomplete)
        #expect(overview.catalog.explanation == "存储枚举没有回报名称，也没有游戏入口。这不是未安装结论。")
        #expect(overview.storage.entries.isEmpty)
        #expect(overview.storage.available == true)
        #expect(overview.storage.reportedStorageCount == 0)
    }

    @Test("空白环境保持未知；旧 helper JSON 没有存储证据时不编造入口")
    func legacyHelperJSONStaysUnknown() throws {
        let json = #"{"deviceID":"legacy-session","observedAt":0,"isComplete":false,"records":[],"issues":["partial coverage"]}"#
        let decoded = try JSONDecoder().decode(InstalledInventory.self, from: Data(json.utf8))
        #expect(decoded.mtpEvidence == nil)
        #expect(decoded.environmentContext == nil)
        #expect(decoded.issues == ["partial coverage"])
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: decoded, inventoryBelongsToCurrentSession: true)
        #expect(overview.environmentContext == .unknown)
        #expect(overview.storage.available == false)
        #expect(overview.storage.diagnostics == .unknown)
        #expect(overview.catalog.grouping == .incomplete)
        #expect(overview.catalog.grouping != .emptyRecognizedEntry)
        #expect(overview.catalog.grouping != .storageListWithoutGameEntry)
        #expect(overview.catalog.explanation == "清单不完整，没有可展示的记录，也没有这次会话的存储证据。不能据此得出未安装结论。")
        #expect(overview.firmware == .unknown)

        let blankEnvironment = inventory(complete: true, environment: " \n\t ")
        let blank = DeviceSessionOverview.make(discovery: nil, inventory: blankEnvironment, inventoryBelongsToCurrentSession: true)
        #expect(blank.environmentContext == .unknown)
        #expect(blank.catalog.grouping == .complete)
        #expect(blank.catalog.explanation == "清单标记为完整，但没有内容记录，也没有可展示的存储入口证据。缺少记录不是未安装结论。")
    }

    @Test("带记录的旧清单仍能解码，存储区保持未知")
    func legacyJSONWithRecords() throws {
        let json = #"{"deviceID":"legacy-session","observedAt":0,"isComplete":true,"records":[{"id":"r1","titleID":"0100AAAABBBB0000","kind":"base","rawVersion":65536,"name":"base.nsp","objectPath":"Installed games/Game/base.nsp"}],"issues":[]}"#
        let decoded = try JSONDecoder().decode(InstalledInventory.self, from: Data(json.utf8))
        #expect(decoded.records.count == 1)
        #expect(decoded.mtpEvidence == nil)
        let overview = DeviceSessionOverview.make(discovery: nil, inventory: decoded, inventoryBelongsToCurrentSession: false)
        #expect(overview.inventorySession == .previous)
        #expect(overview.catalog.grouping == .complete)
        #expect(overview.catalog.recordCount == 1)
        #expect(overview.storage.available == false)
        #expect(overview.storage.notes == ["这次会话没有存储证据。存储名称、清单入口、游戏目录数和元数据对象数都是未知。"])
        #expect(overview.serialNumber == .unknown)
        #expect(overview.wifiStatus == .unknown)
    }
}
