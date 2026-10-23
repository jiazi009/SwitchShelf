import SwiftUI
import SwitchShelfDomain

struct DeviceView: View {
    @Bindable var model: AppModel
    @State private var recordQuery = ""

    private var state: DeviceConnectionState { model.deviceDiscovery?.state ?? .disconnected }
    private var statusLabel: String {
        if model.isDiscovering { return "正在检测 USB 设备" }
        if model.deviceDiscovery == nil { return "尚未检测设备" }
        return state.label
    }
    private var statusSymbol: String { model.deviceDiscovery == nil ? "cable.connector" : state.symbol }
    private var canRead: Bool { model.canReadInventory }

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
                await model.refreshDevices()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PageHeading(title: "我的 Switch", subtitle: model.deviceSubtitle)
            Spacer()
            Button {
                Task { await model.refreshDevices() }
            } label: {
                Label("重新检测", systemImage: "arrow.clockwise")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.glass)
            .disabled(model.isDiscovering || model.isReadingInventory)
            .help("重新执行只读 USB 检测")
            .accessibilityLabel("重新检测 USB 设备")
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
                                    text: model.inventoryIsCurrentSession ? "清单已读取" : "尚未握手",
                                    systemImage: model.inventoryIsCurrentSession ? "checkmark.shield.fill" : "lock.slash",
                                    tone: model.inventoryIsCurrentSession ? .success : .neutral
                                )
                            }
                        }
                        Text(deviceMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Task { await model.refreshDevices() }
                    } label: {
                        if model.isDiscovering {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("检测")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(model.isDiscovering || model.isReadingInventory)
                    .accessibilityLabel("检测 Switch USB 设备")
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
                                Spacer()
                                Text("VID \(hexDeviceID(device.vendorID)) · PID \(hexDeviceID(device.productID))")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Divider().overlay(Theme.hairline)

                HStack(spacing: 10) {
                    Button {
                        Task { await model.readInventory() }
                    } label: {
                        Label(
                            model.inventory == nil ? "读取已安装内容" : "重新读取已安装内容",
                            systemImage: "list.bullet.rectangle.portrait"
                        )
                        .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canRead)
                    .help(canRead ? "只读枚举设备存储中的已安装条目" : "需要单一 057e:201d MTP 候选设备；检测后可直接读取并执行握手")
                    .accessibilityLabel("读取设备已安装内容，只读")

                    if model.isReadingInventory {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                            Text("正在读取清单…")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(canRead
                             ? "读取会执行一次只读 MTP 握手，仅枚举存储与安装记录，不下载 NSP，不写入设备。"
                             : "未检测到单一 057e:201d MTP 候选设备；请连接数据线并进入 DBI 的 MTP 响应模式后重新检测。")
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
            return "尚未执行设备检测。连接 Switch 并进入 DBI 的 MTP 响应模式后再检测。"
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
                    Text("使用 DBI 连接（只读）")
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
                        title: "打开 DBI 并进入 MTP 响应模式",
                        detail: "在 Switch 上打开 DBI，选择“Run MTP responder”（部分版本可按 X 快捷进入），并停留在该界面。"
                    )
                    instructionStep(
                        3,
                        title: "保持单一客户端",
                        detail: "关闭 Finder、Android File Transfer 等其他 MTP/文件传输客户端，避免并发的 USB 会话干扰读取。"
                    )
                    instructionStep(
                        4,
                        title: "返回此处检测并读取",
                        detail: "点击“重新检测”；检测到单一 057e:201d 候选设备后即可主动读取，读取按钮会执行实际握手。读取期间不要切换 DBI 模式。"
                    )
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.installed)
                    Text("MTP（057e:201d）用于只读已安装清单；DBI 的 USB Backend（057e:3000）是另一模式，当前仅能作描述符候选检测，不会打开或传输。两种模式不能并行占用 USB。安装队列的“检查计划”只看 Mac 本地文件，与设备连接无关。SD／机身存储是计划意向：Backend 主机协议没有目标设置命令，设备端选择和安装结果尚未验证。当前不安装、不删除设备对象或修改存档。")
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
                if model.canReadInventory {
                    Button("立即读取") { Task { await model.readInventory() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canRead)
                }
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
                        TextField("筛选已安装内容、Title ID 或路径", text: $recordQuery)
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

                    let records = filteredRecords(inventory)
                    if records.isEmpty {
                        Text("没有匹配的记录。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(records) { record in
                                recordRow(record)
                            }
                        }
                    }
                } else {
                    Text(inventory.isComplete
                         ? "本次读取到的清单为空。若设备上确有已安装游戏，请检查 DBI 是否显示 Installed games 存储。"
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

    private func filteredRecords(_ inventory: InstalledInventory) -> [InstalledRecord] {
        let query = recordQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let records = inventory.records.filter { record in
            guard !query.isEmpty else { return true }
            let haystack = "\(record.name) \(record.titleID ?? "") \(record.objectPath) \(record.kind.label)"
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            return haystack.localizedStandardContains(query)
        }
        return records.sorted { left, right in
            if left.kind.order != right.kind.order { return left.kind.order < right.kind.order }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
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
