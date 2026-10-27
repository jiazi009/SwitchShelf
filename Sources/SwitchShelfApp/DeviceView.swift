import SwiftUI
import SwitchShelfDomain

struct DeviceView: View {
    @Bindable var model: AppModel
    @State private var recordQuery = ""
    @State private var showInstructions = false

    private var state: DeviceConnectionState { model.deviceDiscovery?.state ?? .disconnected }
    private var overview: DeviceSessionOverview { model.deviceSessionOverview }
    private var statusSymbol: String { model.isReadingInventory ? "arrow.triangle.2.circlepath" : (model.deviceDiscovery == nil ? "cable.connector" : state.symbol) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice {
                        NoticeBanner(notice: notice) { model.perform($0) } onDismiss: { model.notice = nil }
                    }
                    machineCard
                    storageCard
                    contentCard
                    instructionsCard
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PageHeading(title: "我的 Switch", subtitle: model.deviceSubtitle)
            BadgePill(text: "USB", systemImage: "cable.connector", tone: .accent)
            Spacer()
            Button {
                Task { await model.detectAndRead() }
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.glass)
            .disabled(model.isDiscovering || model.isReadingInventory || model.isInstalling || model.wifiBlocksUSB)
            .help("应用会自动检测连接；也可以手动重新检测并读取清单。")
            .accessibilityLabel("检测并读取，只读")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private var machineCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill((model.isDiscovering ? StatusTone.accent : state.tone).soft)
                            .frame(width: 54, height: 54)
                        if model.isDiscovering {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: statusSymbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(state.tone.color)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("机器信息")
                            .font(.system(size: 13, weight: .semibold))
                        HStack(spacing: 7) {
                            Text(overview.connectionLabel)
                                .font(.system(size: 16, weight: .semibold))
                            BadgePill(
                                text: overview.inventorySession.text,
                                systemImage: sessionSymbol,
                                tone: sessionTone
                            )
                        }
                        Text(overview.discoveryMessage.text)
                            .font(.system(size: 11))
                            .foregroundStyle(overview.discoveryMessage.isKnown ? .secondary : .tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }

                Divider().overlay(Theme.hairline)
                VStack(alignment: .leading, spacing: 8) {
                    factRow("清单会话", overview.inventorySession.text, known: overview.inventorySession != .unknown)
                    factRow("观察时间", observationText, known: overview.observedAt != nil)
                    factRow("环境", overview.environmentContext.text, known: overview.environmentContext.isKnown)
                    factRow("清单完整性", overview.completeness.text, known: overview.completeness != .unknown)
                    consoleFactRows
                    issueBlock
                }

                Divider().overlay(Theme.hairline)
                usbBlock

                Divider().overlay(Theme.hairline)
                HStack(spacing: 10) {
                    Button {
                        Task { await model.detectAndRead() }
                    } label: {
                        Label(model.inventoryIsCurrentSession ? "重新读取清单" : "立即检测", systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isDiscovering || model.isReadingInventory || model.isInstalling || model.wifiBlocksUSB)
                    .help("立即重新检测并只读读取设备清单。")
                    .accessibilityLabel("检测并读取，只读")

                    if model.isDiscovering || model.isReadingInventory {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                            Text(model.isDiscovering ? "正在检测 USB…" : "正在读取清单…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(model.wifiBlocksUSB ? "无线连接期间自动 USB 检测已暂停。" : "自动检测已开启 · MTP 连接成功时会播放提示音")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var sessionSymbol: String {
        switch overview.inventorySession {
        case .current: overview.completeness == .complete ? "checkmark.shield.fill" : "exclamationmark.shield"
        case .previous: "clock.arrow.circlepath"
        case .unknown: "questionmark.circle"
        }
    }

    private var sessionTone: StatusTone {
        switch overview.inventorySession {
        case .current: overview.completeness == .complete ? .success : .warning
        case .previous: .warning
        case .unknown: .neutral
        }
    }

    private var observationText: String {
        guard let date = overview.observedAt else { return "未知" }
        return "\(absoluteTime(date)) · \(relativeTime(date))"
    }

    private var consoleFacts: [(String, DeviceSessionOverview.Fact)] {
        [
            ("固件", overview.firmware),
            ("序列号", overview.serialNumber),
            ("电量", overview.battery),
            ("昵称", overview.nickname),
            ("Wi-Fi", overview.wifiStatus)
        ]
    }

    @ViewBuilder
    private var consoleFactRows: some View {
        ForEach(Array(consoleFacts.enumerated()), id: \.offset) { _, item in
            factRow(item.0, item.1.text, known: item.1.isKnown)
        }
    }

    @ViewBuilder
    private var issueBlock: some View {
        switch overview.issues {
        case .unknown:
            factRow("问题", "未知", known: false)
        case .none:
            factRow("问题", "没有列出问题", known: true)
        case .listed(let issues):
            VStack(alignment: .leading, spacing: 5) {
                Text("问题")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var usbBlock: some View {
        switch overview.usb {
        case .unknown:
            factRow("USB 设备", "未知", known: false)
        case .none:
            factRow("USB 设备", "这次检测没有列出候选设备", known: true)
        case .devices(let devices):
            VStack(alignment: .leading, spacing: 7) {
                Text("USB 设备")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(devices) { device in
                    let name = device.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    HStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.accent)
                        Text(name.isEmpty ? "未知" : name)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(name.isEmpty ? "未知" : name)
                        Spacer()
                        Text("VID \(hexDeviceID(device.vendorID)) · PID \(hexDeviceID(device.productID))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func factRow(_ title: String, _ value: String, known: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 168, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(known ? .primary : .tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var instructionsCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("使用 sphaira / DBI 连接")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("首次读取前请按步骤操作")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                DisclosureGroup("连接与排查步骤", isExpanded: $showInstructions) {
                VStack(alignment: .leading, spacing: 10) {
                    instructionStep(
                        1,
                        title: "连接数据线",
                        detail: "用支持数据传输的 USB-C 线连接 Switch 与 Mac；仅充电线不会出现在检测结果中。"
                    )
                    instructionStep(
                        2,
                        title: "在 Switch 上开启 MTP",
                        detail: "sphaira：在网络菜单开启 MTP 和 Games 存储。DBI：选择 Run MTP responder，并开启 Installed games。保持该模式。"
                    )
                    instructionStep(
                        3,
                        title: "保持单一客户端",
                        detail: "完整退出 OpenMTP、Android File Transfer 等其他 MTP 客户端。若 OpenMTP 曾提示设备忙，可先退出“预览”。不要停止系统相机服务。"
                    )
                    instructionStep(
                        4,
                        title: "等待自动连接",
                        detail: "应用会自动检测 USB，并在发现单一 MTP 候选设备后尝试读取。成功建立 MTP 通信时会播放提示音；如未成功，可点击“立即检测”重试。"
                    )
                }
                .padding(.top, 10)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.installed)
                    Text("这里只读取 Games / Installed games 元数据；Mounts、Contents、存档、安装与测速入口不参与扫描。安装队列需核对文件并确认，在 sphaira 进入 MTP Install 并选择目标存储。发送期间暂停清单读取；发送完成不等于安装成功。侧边栏「无线连接」是另一条 DBI FTP，不会从本页打开。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Theme.installed.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func instructionStep(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .background(Theme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var storageCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.connected.to.line.below")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("本次可见存储")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if overview.storage.available {
                        BadgePill(
                            text: overview.storage.diagnostics == .diagnosticsOnly ? "仅为存储诊断" : "已读取存储名",
                            systemImage: overview.storage.diagnostics == .diagnosticsOnly ? "list.bullet.rectangle" : "checklist",
                            tone: overview.storage.diagnostics == .diagnosticsOnly ? .warning : .accent
                        )
                    }
                }
                if overview.storage.available {
                    VStack(alignment: .leading, spacing: 8) {
                        factRow("仅为存储诊断", overview.storage.diagnostics.text, known: overview.storage.diagnostics != .unknown)
                        factRow("游戏目录数", countText(overview.storage.gameDirectoryCount), known: overview.storage.gameDirectoryCount != nil)
                        factRow("元数据对象数", countText(overview.storage.metadataObjectCount), known: overview.storage.metadataObjectCount != nil)
                        factRow("回报存储项数", countText(overview.storage.reportedStorageCount), known: overview.storage.reportedStorageCount != nil)
                    }
                    if !overview.storage.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(overview.storage.entries) { entry in
                                HStack(spacing: 8) {
                                    Text(entry.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(entry.name)
                                    Spacer(minLength: 8)
                                    Text(entry.roleLabel)
                                        .font(.system(size: 9.5, weight: .semibold))
                                        .foregroundStyle(entry.isInventoryEntry ? Theme.accent : .secondary)
                                }
                            }
                        }
                        .padding(10)
                        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    ForEach(Array(overview.storage.entryNamesMissingFromList.enumerated()), id: \.offset) { _, name in
                        Text("清单入口未出现在已列出的存储名中：\(name)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(overview.storage.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(Array(overview.storage.notes.enumerated()), id: \.offset) { _, note in
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var contentCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("内容目录")
                        .font(.system(size: 13, weight: .semibold))
                    BadgePill(
                        text: overview.catalog.title,
                        systemImage: catalogSymbol,
                        tone: catalogTone
                    )
                    if model.inventoryIsCurrentSession {
                        BadgePill(
                            text: "本地匹配 \(model.locallyMatchedGameCount) 款",
                            systemImage: "gamecontroller.fill",
                            tone: .accent
                        )
                    }
                    Spacer()
                    if let count = overview.catalog.recordCount {
                        Text("\(count) 条记录")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                if model.inventory != nil, !model.inventoryIsCurrentSession {
                    Label(model.inventoryCacheSaved
                          ? "这是上次读取后保存在本机的清单，不能代表设备当前的安装状态。"
                          : "这是上次读取的清单，仅保存在当前应用内存中；不能代表设备当前的安装状态。", systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let comparison = model.inventoryComparison {
                    Label(comparison, systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(overview.catalog.explanation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let inventory = model.inventory, !inventory.records.isEmpty {
                    HStack(spacing: 8) {
                        ForEach([ContentKind.base, .update, .dlc], id: \.self) { kind in
                            BadgePill(text: "\(kind.label) \(inventory.records.filter { $0.kind == kind }.count)", tone: .accent)
                        }
                    }
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField("筛选目录、本地游戏、Title ID 或路径", text: $recordQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .accessibilityLabel("筛选内容目录")
                        if !recordQuery.isEmpty {
                            Button {
                                recordQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除内容目录筛选")
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                    let groups = filteredGroups(inventory)
                    if groups.isEmpty {
                        Text("没有匹配的记录。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(groups) { group in
                                directorySection(group)
                            }
                        }
                    }
                } else if overview.catalog.grouping == .notRead {
                    Button("检测并读取") { Task { await model.detectAndRead() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isDiscovering || model.isReadingInventory || model.isInstalling || model.wifiBlocksUSB)
                }

                HStack {
                    Spacer()
                    Button("复制诊断摘要") { model.copyDiagnostics() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("复制设备与库存诊断摘要")
                }
            }
        }
    }

    private var catalogSymbol: String {
        switch overview.catalog.grouping {
        case .notRead: "tray"
        case .complete: "checkmark.circle.fill"
        case .incomplete: "exclamationmark.triangle.fill"
        case .emptyRecognizedEntry: "tray"
        case .storageListWithoutGameEntry: "externaldrive"
        case .storageDiagnosticsOnly: "list.bullet.rectangle"
        }
    }

    private var catalogTone: StatusTone {
        switch overview.catalog.grouping {
        case .notRead: .neutral
        case .complete: .success
        case .incomplete, .emptyRecognizedEntry, .storageListWithoutGameEntry, .storageDiagnosticsOnly: .warning
        }
    }

    private func countText(_ value: Int?) -> String {
        value.map(String.init) ?? "未知"
    }

    private func filteredGroups(_ inventory: InstalledInventory) -> [InventoryDirectoryGroup] {
        let query = recordQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let groups = model.inventoryDirectoryGroups(from: inventory.records)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let folded: (String) -> String = {
                $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            }
            let titleHit = group.localGameTitles.contains { folded($0).localizedStandardContains(query) }
            let directoryHit = folded(group.directoryName).localizedStandardContains(query)
            if titleHit || directoryHit { return group }
            let records = group.records.filter { record in
                let haystack = folded("\(record.name) \(record.titleID ?? "") \(record.objectPath) \(record.kind.label)")
                return haystack.localizedStandardContains(query)
            }
            guard !records.isEmpty else { return nil }
            return InventoryDirectoryGroup(
                id: group.id,
                directoryName: group.directoryName,
                records: records,
                localGameTitles: group.localGameTitles
            )
        }
    }

    private func directorySection(_ group: InventoryDirectoryGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.directoryName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if group.localGameTitles.isEmpty {
                    Text("没有对应的本地游戏")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(group.localGameTitles.joined(separator: "、"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                        .help(group.localGameTitles.joined(separator: "、"))
                }
            }
            Text("按游戏目录分组 · \(group.records.count) 条记录")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            ForEach(group.records) { record in
                recordRow(record)
            }
        }
    }

    private func recordRow(_ record: InstalledRecord) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ContentKindIcon(kind: record.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.name)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Text(record.kind.label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Spacer(minLength: 0)
                    Text(formatVersion(record.rawVersion) ?? "版本未知")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(displayTitleID(record.titleID))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(record.objectPath)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(8)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.6)
        }
        .contextMenu {
            if let titleID = record.titleID {
                Button("复制 Title ID") { model.copyTitleID(titleID) }
            }
            Button("复制对象路径") { model.copyToPasteboard(record.objectPath) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name)，\(record.kind.label)，\(displayTitleID(record.titleID))")
    }
}
