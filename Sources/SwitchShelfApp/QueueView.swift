import SwiftUI
import SwitchShelfDomain

struct QueueView: View {
    @Bindable var model: AppModel
    @State private var showClearAlert = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice {
                        NoticeBanner(notice: notice) { model.perform($0) } onDismiss: { model.notice = nil }
                    }
                    executionCard
                    if model.plan.isEmpty {
                        EmptyStateView(
                            symbol: "arrow.up.arrow.down.circle",
                            title: "安装队列为空",
                            message: "在游戏库选择游戏并“加入安装队列”。队列只保存本地计划，不会向设备写入任何内容。",
                            actionTitle: "浏览游戏库",
                            action: { model.showAllGames() }
                        )
                        .frame(minHeight: 320)
                    } else {
                        VStack(spacing: 12) {
                            ForEach(Array(model.plan.enumerated()), id: \.element.id) { index, item in
                                PlanItemCard(
                                    model: model,
                                    item: item,
                                    index: index,
                                    count: model.plan.count
                                )
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.canvas)
        .alert("清空安装队列？", isPresented: $showClearAlert) {
            Button("清空队列", role: .destructive) { model.clearPlan() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除本地安装计划，不会删除任何游戏文件或设备内容。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PageHeading(title: "安装队列", subtitle: model.pageSubtitle)
            Spacer()
            Button {
                model.exportPlan()
            } label: {
                Label("导出计划", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.glass)
            .disabled(model.plan.isEmpty)
            .help("导出包含文件清单与备注的本地 JSON 计划")
            .accessibilityLabel("导出安装计划")

            Menu {
                Button("复制计划摘要") { model.copyPlanSummary() }
                    .disabled(model.plan.isEmpty)
                Button("导出 JSON…") { model.exportPlan() }
                    .disabled(model.plan.isEmpty)
                Divider()
                Button("清空队列…", role: .destructive) { showClearAlert = true }
                    .disabled(model.plan.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .help("更多队列操作")
            .accessibilityLabel("更多安装队列操作")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private var executionCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .frame(width: 36, height: 36)
                .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text("安装执行暂不可用")
                        .font(.system(size: 13, weight: .semibold))
                    BadgePill(text: "未启用", systemImage: "lock.fill", tone: .warning)
                }
                Text("队列会自动保存在本机，可编辑内容、目标与顺序。开始安装需要已验证的 DBI Backend 传输通道、明确的成功/失败语义，以及经授权的测试包与目标；在这些条件成立前不会执行，也不会显示虚假进度。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("开始安装") {}
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(true)
                        .help("不可用：安装传输协议与目标路径尚未验证")
                        .accessibilityHint("当前不可用。安装传输协议与目标路径尚未验证。")
                    Button("查看设备与 MTP 说明") { model.showDevice() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityLabel("查看设备连接与安装条件说明")
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.warning.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.20), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PlanItemCard: View {
    @Bindable var model: AppModel
    var item: PlanItem
    var index: Int
    var count: Int
    @State private var expanded = false

    private var game: Game? { model.games.first { $0.id == item.gameID } }
    private var includedCount: Int { item.includedContents.count }

    private var noteBinding: Binding<String> {
        Binding(
            get: { model.planItem(for: item.gameID)?.note ?? item.note },
            set: { model.updatePlanNote(item.id, note: $0) }
        )
    }

    private var targetBinding: Binding<InstallTarget> {
        Binding(
            get: { model.planItem(for: item.gameID)?.target ?? item.target },
            set: { model.updatePlanTarget(item.id, target: $0) }
        )
    }

    var body: some View {
        SurfaceCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        if let game {
                            CoverArtwork(game: game, cornerRadius: 7)
                        } else {
                            CoverPlaceholder(title: item.title, seed: item.gameID)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                    }
                    .frame(width: 50, height: 67)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(2)
                            Spacer(minLength: 4)
                            Text("第 \(index + 1) 项")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        HStack(spacing: 6) {
                            if let titleID = item.titleID {
                                Text(displayTitleID(titleID))
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("\(includedCount)/\(item.contents.count) 项 · \(formatByteCount(item.byteCount))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Image(systemName: item.target.symbol)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Picker("安装位置", selection: targetBinding) {
                                    ForEach(InstallTarget.allCases) { target in
                                        Text(target.label).tag(target)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .frame(width: 92)
                                .help("仅记录本地计划，不会立即写入设备")
                                .accessibilityLabel("计划安装位置")
                            }
                            if item.note.isEmpty {
                                Text("无备注")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text(item.note)
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }

                    VStack(spacing: 2) {
                        Button {
                            model.movePlanItem(item.id, direction: -1)
                        } label: {
                            Image(systemName: "chevron.up").frame(width: 22, height: 17).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                        .help("上移")
                        .accessibilityLabel("上移 \(item.title)")
                        Button {
                            model.movePlanItem(item.id, direction: 1)
                        } label: {
                            Image(systemName: "chevron.down").frame(width: 22, height: 17).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index >= count - 1)
                        .help("下移")
                        .accessibilityLabel("下移 \(item.title)")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                    Button {
                        model.removePlanItem(item.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("从队列移除此项")
                    .accessibilityLabel("从队列移除 \(item.title)")
                }

                TextField("备注（仅保存在本机，例如：先备份存档）", text: noteBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .lineLimit(1...2)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.6)
                    }
                    .accessibilityLabel("安装备注")

                if item.contents.isEmpty {
                    InlineErrorText(text: "该计划没有本地内容文件；请从游戏库重新加入。")
                } else {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(spacing: 4) {
                            ForEach(item.contents) { content in
                                contentToggle(content)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        HStack(spacing: 6) {
                            Text("内容清单")
                                .font(.system(size: 10.5, weight: .medium))
                            Text("\(includedCount)/\(item.contents.count)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if includedCount == 0 {
                                Text("至少选择一项")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Theme.warning)
                            }
                            Spacer()
                        }
                    }
                    .font(.system(size: 10.5))
                    .accessibilityLabel("展开内容清单")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func contentToggle(_ content: PlanContent) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.planItem(for: item.gameID)?.contents.first { $0.id == content.id }?.included ?? content.included },
                set: { model.setPlanContentIncluded(item.id, contentID: content.id, included: $0) }
            )
        ) {
            HStack(spacing: 7) {
                Image(systemName: content.kind.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 14)
                Text(content.fileName)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(content.kind.label)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text(content.version ?? "版本未知")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(formatByteCount(content.byteCount))
                    .font(.system(size: 8.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel("包含 \(content.fileName)，\(content.kind.label)，\(formatByteCount(content.byteCount))")
    }
}
