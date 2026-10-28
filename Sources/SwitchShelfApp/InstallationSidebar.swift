import SwiftUI
import SwitchShelfDomain
import SwitchShelfDevice

struct InstallationSidebar: View {
    @Bindable var model: AppModel
    let installationMotion: Namespace.ID

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let notice = model.notice {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notice.title).font(.caption.bold())
                                Text(notice.message).font(.caption2).foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 9))
                        }
                        ForEach(Array(model.plan.enumerated()), id: \.element.id) { index, item in
                            StagedGameCard(model: model, item: item, index: index,
                                           installationMotion: installationMotion)
                                .id(item.id)
                                .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        }
                        if model.plan.isEmpty {
                            Text("点击左侧游戏卡片加入待选区")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                        if !model.installStatuses.isEmpty { transferStatus }
                    }
                    .padding(14)
                }
                .accessibilityIdentifier("staging-viewport")
                .onChange(of: model.plan.count) { old, count in
                    if count > old, let last = model.plan.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            Divider()
            installControls
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(Theme.inspector)
        .accessibilityIdentifier("installation-sidebar")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("安装待选区").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(model.plan.count) 款").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "cable.connector").foregroundStyle(Theme.accent)
                Text(model.installationConnectionBlocker ?? "USB 已发现 · 安装模式需在设备确认")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            Button("连接指引") { model.showConnectionGuide = true }
                .font(.caption)
                .popover(isPresented: $model.showConnectionGuide, arrowEdge: .leading) {
                    InstallationConnectionGuide(model: model)
                }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var installControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("计划目标").font(.caption).foregroundStyle(.secondary)
                Picker("计划目标", selection: Binding(
                    get: { () -> InstallTarget? in
                        guard let first = model.plan.first?.target else { return .sd }
                        return model.plan.allSatisfy { $0.target == first } ? first : nil
                    },
                    set: { if let target = $0 { model.setAllPlanTargets(target) } }
                )) {
                    Text("目标不一致").tag(InstallTarget?.none).disabled(true)
                    ForEach(InstallTarget.allCases) { target in Text(target.label).tag(Optional(target)) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small)
                .disabled(model.plan.isEmpty || model.installationPlanLocked)
            }
            Text("默认本体 + 全部 DLC + 最新更新 · 目标以设备端选择为准")
                .font(.system(size: 9)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let issue = model.queueValidationIssues.first {
                Text(issue).font(.caption2).foregroundStyle(Theme.warning).lineLimit(3).help(issue)
            }
            HStack {
                Text("\(model.plan.count) 款游戏")
                Spacer()
                Text(formatByteCount(model.planTotalBytes)).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await model.beginStagedInstallation() }
            } label: {
                Label(model.isPreparingInstallation ? "检查文件…" : model.isInstalling ? "安装进行中" : "开始安装",
                      systemImage: model.isInstalling ? "arrow.triangle.2.circlepath" : "arrow.down.to.line")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!model.canBeginStagedInstallation)
            .help("自动检查文件后核对设备与目标；确认后按顺序安装，不需要跳转队列页。")
            .accessibilityIdentifier("begin-staged-installation")
            if model.isInstalling {
                Button("停止当前传输", role: .destructive) { model.cancelMTPInstallation() }
                    .font(.caption)
            }
        }
        .padding(16)
    }

    private var transferStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.isInstalling ? "串行安装进度" : "最近传输结果").font(.caption.bold())
            ForEach(model.installStatuses) { status in
                VStack(alignment: .leading, spacing: 3) {
                    Text(status.item.request.name).font(.caption2).lineLimit(1)
                    Text(statusLabel(status)).font(.caption2).foregroundStyle(.secondary)
                    if case .sending = status.state {
                        ProgressView(value: Double(status.bytesSubmitted), total: Double(max(status.item.request.byteCount, 1)))
                    }
                }
            }
            Text("文件发送完成不等于设备已确认安装。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ status: SphairaBatchStatus) -> String {
        switch status.state {
        case .waiting: "等待发送"
        case .sending: "正在发送 \(formatByteCount(Int64(clamping: status.bytesSubmitted)))"
        case .transferred: "已发送，等待设备确认"
        case .stopped(let reason): "已停止：\(reason)"
        }
    }
}

private struct StagedGameCard: View {
    @Bindable var model: AppModel
    let item: PlanItem
    let index: Int
    let installationMotion: Namespace.ID
    @State private var expanded = false

    private var game: Game? { model.games.first { $0.id == item.gameID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let game { CoverArtwork(game: game, cornerRadius: 6) }
                    else { CoverPlaceholder(title: item.title, seed: item.id) }
                }
                .frame(width: 46, height: 60)
                .modifier(InstallationMotion(id: item.gameID, namespace: installationMotion))
                .accessibilityIdentifier("staging-cover-\(item.gameID)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        .accessibilityIdentifier("staged-title-\(item.gameID)")
                    Text("\(item.includedContents.count) 个文件 · \(formatByteCount(item.byteCount))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button { model.movePlanItem(item.id, direction: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0).accessibilityLabel("上移\(item.title)")
                        Button { model.movePlanItem(item.id, direction: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == model.plan.count - 1).accessibilityLabel("下移\(item.title)")
                        Spacer()
                        Button { withAnimation(.snappy(duration: 0.25)) { model.removePlanItem(item.id) } } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .accessibilityLabel("移除待选游戏\(item.title)")
                        .accessibilityIdentifier("remove-staged-\(item.gameID)")
                    }
                    .buttonStyle(.borderless).font(.system(size: 10))
                }
            }
            DisclosureGroup("文件与更新选择", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(item.contents) { content in
                        Toggle(isOn: Binding(
                            get: { model.planItem(for: item.gameID)?.contents.first { $0.id == content.id }?.included ?? false },
                            set: { model.setPlanContentIncluded(item.id, contentID: content.id, included: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(content.kind.label) · \(content.version ?? "版本未知")")
                                Text(content.fileName).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox).font(.system(size: 10))
                        .help(content.fileName)
                    }
                    if model.needsUpdateChoice(item) {
                        Text("无法可靠确定最新更新，请选择文件或明确略过。")
                            .foregroundStyle(Theme.warning)
                        Button("本次不安装更新") { model.omitUpdatesForThisInstallation(item.id) }
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(size: 10.5))
        }
        .padding(11)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
        .disabled(model.installationPlanLocked)
        .onAppear { if model.needsUpdateChoice(item) { expanded = true } }
        .accessibilityIdentifier("staged-game-\(item.gameID)")
    }
}

struct InstallationConnectionGuide: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("连接与安装指引").font(.headline)
                Spacer()
                Button { model.showConnectionGuide = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("关闭连接指引")
            }
            Text("1. 用支持数据传输的 USB 线连接一台 Switch。")
            Text("2. 打开 sphaira，进入 MTP Install 并保持该页面。")
            Text("3. 在 Switch 上选择 SD 卡或机身存储，与本机计划一致。")
            Text("4. 完整退出 OpenMTP、预览等其他 MTP 客户端；无线 FTP 需先断开。")
            Text("USB 识别、游戏清单读取成功都不代表已进入安装模式。开始前会再次检查文件并要求确认，实际目标始终由设备端控制。")
                .foregroundStyle(.secondary)
            Button("查看设备连接状态") {
                model.showConnectionGuide = false
                model.showDevice()
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
    }
}
