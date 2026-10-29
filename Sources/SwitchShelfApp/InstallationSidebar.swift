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
            StagedGameList(model: model, installationMotion: installationMotion)
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
                    .font(.system(.caption)).foregroundStyle(.secondary).lineLimit(2)
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
            Text("有 XCI 时默认只安装整合包，不附带其他本体、更新和 DLC · 目标以设备端选择为准")
                .font(.system(.caption2)).foregroundStyle(.secondary)
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
            installProgress
            Button {
                Task { await model.beginStagedInstallation() }
            } label: {
                Label(model.isPreparingInstallation ? "检查文件…" : model.isInstalling ? "安装进行中" : model.isVerifyingInstall ? "正在核对安装" : "开始安装",
                      systemImage: model.isInstalling ? "arrow.triangle.2.circlepath" : "arrow.down.to.line")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!model.canBeginStagedInstallation)
            .help("检查本地文件后立即按顺序发送。进度显示在待选区，发送完成不等于设备已确认安装。")
            .accessibilityIdentifier("begin-staged-installation")
            if model.isInstalling {
                Button("停止当前传输", role: .destructive) { model.cancelMTPInstallation() }
                    .font(.caption)
            } else if model.isVerifyingInstall {
                Button("停止核对") { model.cancelMTPInstallation() }
                    .font(.caption)
                    .help("停止读取设备清单，保留已发送的游戏和待选文件。")
                    .accessibilityIdentifier("cancel-install-verification")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var installProgress: some View {
        if model.isPreparingInstallation, model.installStatuses.isEmpty {
            progressBlock(title: "正在检查文件", detail: "只检查本地文件，尚未连接设备。", fraction: nil, tone: .accent)
        } else if model.isInstalling, model.installStatuses.isEmpty {
            progressBlock(title: "准备发送", detail: "等待第一项传输状态。", fraction: nil, tone: .accent)
        } else if let summary = transferSummary(model.installStatuses, confirmed: model.installListConfirmed, verifying: model.isVerifyingInstall) {
            let submitted = model.installStatuses.reduce(UInt64(0)) { adding($0, $1.bytesSubmitted) }
            let total = model.installStatuses.reduce(UInt64(0)) { adding($0, $1.item.request.byteCount) }
            let detail = model.installListConfirmed
                ? "已重新读取设备清单，所选游戏显示为已安装。"
                : model.isVerifyingInstall
                    ? model.verificationDetail ?? "正在通过 libusb 读取 Games 清单；确认所选内容后显示安装成功。"
                    : "已提交 \(formatByteCount(Int64(clamping: submitted))) / \(formatByteCount(Int64(clamping: total)))。发送完成不等于设备已确认安装。"
            progressBlock(
                title: summary.headline,
                detail: detail,
                fraction: summary.fraction,
                tone: summary.tone
            )
        }
    }

    private func progressBlock(title: String, detail: String, fraction: Double?, tone: StatusTone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone.color)
            if let fraction {
                ProgressView(value: fraction).tint(tone.color)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(detail)
                .font(.system(.caption2))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)。\(detail)")
    }
}

/// Plan rows stay independent of the connection-status line, so a USB poll
/// cannot redraw the staged games when that line changes.
private struct StagedGameList: View {
    @Bindable var model: AppModel
    let installationMotion: Namespace.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.installationAnimationsEnabled) private var animationsEnabled

    var body: some View {
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
                            .transition(InstallationStagingMotion.transition(
                                completed: model.completedInstallGameIDs.contains(item.gameID),
                                reduceMotion: reduceMotion,
                                enabled: animationsEnabled))
                    }
                    if model.plan.isEmpty {
                        Text("点击左侧游戏卡片加入待选区")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(14)
                .animation(InstallationStagingMotion.animation(
                    reduceMotion: reduceMotion, enabled: animationsEnabled), value: model.plan.map(\.id))
            }
            .accessibilityIdentifier("staging-viewport")
            .onChange(of: model.plan.count) { old, count in
                if count > old, let last = model.plan.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
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
                .modifier(InstallationMotion(id: item.gameID, namespace: installationMotion,
                                             enabled: !model.completedInstallGameIDs.contains(item.gameID)))
                .accessibilityIdentifier("staging-cover-\(item.gameID)")
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        .accessibilityIdentifier("staged-title-\(item.gameID)")
                    Text("\(item.includedContents.count) 个文件 · \(formatByteCount(item.byteCount))")
                        .font(.system(.caption)).foregroundStyle(.secondary)
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
                    .buttonStyle(.borderless).font(.system(.caption))
                    .disabled(model.installationPlanLocked)
                }
            }
            if let summary = transferSummary(transferStatuses(for: item, in: model.installStatuses), confirmed: model.installListConfirmed, verifying: model.isVerifyingInstall) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title)
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(summary.tone.color)
                        .lineLimit(2)
                    ProgressView(value: summary.fraction)
                        .tint(summary.tone.color)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.title) \(summary.title)")
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
                                Text(content.fileName).font(.system(.caption2)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .toggleStyle(.checkbox).font(.system(.caption))
                        .help(content.fileName)
                    }
                    if let reminder = model.baseSelectionReminder(item) {
                        Text(reminder).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.needsUpdateChoice(item) {
                        Text("无法可靠确定最新更新，请选择文件或明确略过。")
                            .foregroundStyle(Theme.warning)
                        Button("本次不安装更新") { model.omitUpdatesForThisInstallation(item.id) }
                    }
                }
                .padding(.top, 6)
            }
            .font(.system(.caption))
            .disabled(model.installationPlanLocked)
        }
        .padding(11)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { if model.needsUpdateChoice(item) || model.baseSelectionReminder(item) != nil { expanded = true } }
        .accessibilityIdentifier("staged-game-\(item.gameID)")
    }
}

private struct TransferSummary {
    var headline: String
    var title: String
    var fraction: Double
    var tone: StatusTone
}

private func adding(_ total: UInt64, _ value: UInt64) -> UInt64 {
    let (sum, overflow) = total.addingReportingOverflow(value)
    return overflow ? .max : sum
}

private func transferStatuses(for item: PlanItem, in statuses: [SphairaBatchStatus]) -> [SphairaBatchStatus] {
    let names = Set(item.includedContents.map(\.fileName))
    return statuses.filter { $0.item.gameTitle == item.title && names.contains($0.item.request.name) }
}

private func transferSummary(_ statuses: [SphairaBatchStatus], confirmed: Bool, verifying: Bool) -> TransferSummary? {
    guard !statuses.isEmpty else { return nil }
    let submitted = statuses.reduce(UInt64(0)) { adding($0, $1.bytesSubmitted) }
    let total = statuses.reduce(UInt64(0)) { adding($0, $1.item.request.byteCount) }
    let fraction = total == 0 ? 0 : min(1, Double(submitted) / Double(total))
    if let stopped = statuses.first(where: { if case .stopped = $0.state { true } else { false } }),
       case .stopped(let reason) = stopped.state {
        let detail = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return TransferSummary(headline: "已停止", title: detail.isEmpty ? "已停止" : "已停止：\(detail)", fraction: fraction, tone: .danger)
    }
    if statuses.contains(where: { if case .sending = $0.state { true } else { false } }) {
        if statuses.contains(where: { $0.phase == "waiting" }) {
            let title = "上一份已发送，等待 Switch 完成安装后继续"
            return TransferSummary(headline: title, title: title, fraction: fraction, tone: .warning)
        }
        let done = statuses.filter { if case .transferred = $0.state { true } else { false } }.count
        let title = "正在发送 · \(done)/\(statuses.count)"
        return TransferSummary(headline: title, title: title, fraction: fraction, tone: .accent)
    }
    if statuses.allSatisfy({ if case .transferred = $0.state { true } else { false } }) {
        if confirmed {
            return TransferSummary(headline: "游戏安装成功", title: "游戏安装成功", fraction: 1, tone: .success)
        }
        if verifying {
            return TransferSummary(headline: "正在核对已安装清单", title: "正在核对已安装清单", fraction: 1, tone: .accent)
        }
        return TransferSummary(headline: "已发送，待设备确认", title: "已发送，待设备确认", fraction: 1, tone: .warning)
    }
    if statuses.allSatisfy({ if case .waiting = $0.state { true } else { false } }) {
        return TransferSummary(headline: "等待发送", title: "等待发送", fraction: 0, tone: .neutral)
    }
    return TransferSummary(headline: "发送未完成", title: "发送未完成", fraction: fraction, tone: .warning)
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
            Text("USB 识别、游戏清单读取成功都不代表已进入安装模式。点击开始安装会检查文件并立即发送，实际目标始终由设备端控制。")
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
