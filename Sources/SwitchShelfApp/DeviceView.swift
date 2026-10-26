import SwiftUI
import SwitchShelfDomain

struct DeviceView: View {
    @Bindable var model: AppModel
    @State private var recordQuery = ""

    private var state: DeviceConnectionState { model.deviceDiscovery?.state ?? .disconnected }
    private var statusLabel: String {
        if model.isDiscovering { return "正在检测 USB 设备" }
        if model.isReadingInventory { return "正在读取已安装清单" }
        if model.deviceDiscovery == nil { return "尚未检测设备" }
        return state.label
    }
    private var statusSymbol: String { model.isReadingInventory ? "arrow.triangle.2.circlepath" : (model.deviceDiscovery == nil ? "cable.connector" : state.symbol) }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice {
                        NoticeBanner(notice: notice) { model.perform($0) } onDismiss: { model.notice = nil }
                    }
                    statusCard
                    instructionsCard
                    if let inventory = model.inventory {
                        inventoryCard(inventory)
                    } else {
                        notReadCard
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.canvas)
        .task {
            if model.deviceDiscovery == nil {
                await model.detectAndRead()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PageHeading(title: "我的 Switch", subtitle: model.deviceSubtitle)
            BadgePill(text: "USB", systemImage: "cable.connector", tone: .accent)
            Spacer()
            Button {
                Task { await model.detectAndRead() }
            } label: {
                Label("检测并读取", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.glass)
            .disabled(model.isDiscovering || model.isReadingInventory || model.isInstalling || model.wifiBlocksUSB)
            .help("只读检测 USB。若发现单一 057e:201d 且 OpenMTP 未运行，会继续读取清单。")
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

    private var statusCard: some View {
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
                        HStack(spacing: 7) {
                            Text(statusLabel)
                                .font(.system(size: 16, weight: .semibold))
                            if !model.isDiscovering, model.deviceDiscovery != nil {
                                BadgePill(
                                    text: model.inventoryIsCurrentSession ? (model.inventory?.isComplete == true ? "清单完整" : "清单待确认") : "尚未握手",
                                    systemImage: model.inventoryIsCurrentSession
                                        ? (model.inventory?.isComplete == true ? "checkmark.shield.fill" : "exclamationmark.shield")
                                        : "lock.slash",
                                    tone: model.inventoryIsCurrentSession ? (model.inventory?.isComplete == true ? .success : .warning) : .neutral
                                )
                            }
                        }
                        Text(deviceMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                }

                if let devices = model.deviceDiscovery?.devices, !devices.isEmpty {
                    Divider().overlay(Theme.hairline)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("检测到的 USB 设备")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(devices) { device in
                            HStack(spacing: 8) {
                                Image(systemName: "cable.connector")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.accent)
                                Text(device.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(device.name)
                                Spacer()
                                Text("VID \(hexDeviceID(device.vendorID)) · PID \(hexDeviceID(device.productID))")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                        }
                    }
                }

                Divider().overlay(Theme.hairline)

                HStack(spacing: 10) {
                    Button {
                        Task { await model.detectAndRead() }
                    } label: {
                        Label("检测并读取", systemImage: "list.bullet.rectangle.portrait")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isDiscovering || model.isReadingInventory || model.isInstalling || model.wifiBlocksUSB)
                    .help("只读检测 USB。若发现单一 057e:201d 且 OpenMTP 未运行，会继续读取清单，不下载 NSP，不写入设备。重新枚举会使旧清单失效；读取失败且 USB 候选未变时保留上次成功清单。")
                    .accessibilityLabel("检测并读取，只读")

                    if model.isDiscovering || model.isReadingInventory {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                            Text(model.isDiscovering ? "正在检测 USB…" : "正在读取清单…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("先检测 USB。只有一台 057e:201d 且 OpenMTP 未运行时，会继续只读读取 Games 或 Installed games。")
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

    private var deviceMessage: String {
        if model.isDiscovering { return "正在通过 IOKit 执行只读 USB 枚举。" }
        guard let discovery = model.deviceDiscovery else {
            return "尚未执行设备检测。连接 Switch 并开启 sphaira 或 DBI 的 MTP 后，点击检测并读取。"
        }
        return discovery.message
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
                        title: "返回此处检测并读取",
                        detail: "点击“检测并读取”，启动后也会自动走这一次。单一 057e:201d 且没有 OpenMTP 时会继续读取。重新枚举 USB 会使旧清单失效；同一次 USB 候选上读取失败时，保留上次成功清单。"
                    )
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.installed)
                    Text("这里只读取 Games / Installed games 元数据；Mounts、Contents、存档、安装与测速入口不参与扫描。队列中的单文件安装测试需单独确认，在 sphaira 进入 MTP Install 并选择目标存储。安装时暂停清单读取；发送完成不等于安装成功。侧边栏「无线连接」是另一条 DBI FTP，不会从本页打开。")
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

    private var notReadCard: some View {
        SurfaceCard(padding: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("尚未读取设备清单")
                        .font(.system(size: 12, weight: .semibold))
                    Text("安装状态只使用当前会话读取到的设备清单；不会根据设备名称、本地文件名或上次清单推断安装成功。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("检测并读取") { Task { await model.detectAndRead() } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isDiscovering || model.isReadingInventory || model.isInstalling || model.wifiBlocksUSB)
            }
        }
    }

    private func inventoryCard(_ inventory: InstalledInventory) -> some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("设备已安装内容")
                        .font(.system(size: 13, weight: .semibold))
                    BadgePill(
                        text: inventory.isComplete ? "清单完整" : "清单不完整",
                        systemImage: inventory.isComplete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tone: inventory.isComplete ? .success : .warning
                    )
                    if model.inventoryIsCurrentSession {
                        BadgePill(
                            text: "本地匹配 \(model.locallyMatchedGameCount) 款",
                            systemImage: "gamecontroller.fill",
                            tone: .accent
                        )
                    }
                    Spacer()
                    Text("\(inventory.records.count) 条记录 · \(relativeTime(inventory.observedAt))")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                if let environment = inventory.environmentContext, !environment.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 9))
                        Text("环境：\(environment)")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(.secondary)
                }

                if let evidence = inventory.mtpEvidence {
                    inventoryEvidence(evidence, inventory: inventory)
                }

                if !inventory.issues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(inventory.issues.enumerated()), id: \.offset) { _, issue in
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

                if !inventory.records.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        TextField("筛选目录、本地游戏、Title ID 或路径", text: $recordQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .accessibilityLabel("筛选已安装内容")
                        if !recordQuery.isEmpty {
                            Button {
                                recordQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除已安装内容筛选")
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
                } else {
                    Text(inventory.isComplete
                         ? "本次已识别的游戏存储返回空清单。若与设备本机显示不符，请核对 sphaira 的 Games 或 DBI 的 Installed games。"
                         : "清单不完整且没有可展示的记录；不会据此声称设备未安装任何游戏。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    private func inventoryEvidence(_ evidence: MTPInventoryEvidence, inventory: InstalledInventory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(evidence.inventoryStorageNames.isEmpty ? "未提供游戏清单入口" : evidence.inventoryStorageNames.joined(separator: "、"),
                      systemImage: "externaldrive.connected.to.line.below")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !evidence.storageDiagnosticsOnly && !evidence.inventoryStorageNames.isEmpty {
                    Text("\(evidence.gameDirectoryCount) 个游戏目录")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            if !inventory.records.isEmpty {
                HStack(spacing: 8) {
                    ForEach([ContentKind.base, .update, .dlc], id: \.self) { kind in
                        BadgePill(text: "\(kind.label) \(inventory.records.filter { $0.kind == kind }.count)", tone: .accent)
                    }
                }
            }
            DisclosureGroup("设备报告的存储入口（\(evidence.reportedStorageCount) 项）") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(evidence.reportedStorageNames.enumerated()), id: \.offset) { _, name in
                        HStack {
                            Text(name).font(.system(size: 10.5))
                            Spacer()
                            Text(evidence.inventoryStorageNames.contains(name) ? "清单来源" : "已发现")
                                .font(.system(size: 9.5))
                                .foregroundStyle(evidence.inventoryStorageNames.contains(name) ? Theme.accent : .secondary)
                        }
                    }
                    if evidence.reportedStorageCount > evidence.reportedStorageNames.count {
                        Text("仅显示前 \(evidence.reportedStorageNames.count) 项。")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 10.5))
        }
        .padding(12)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
