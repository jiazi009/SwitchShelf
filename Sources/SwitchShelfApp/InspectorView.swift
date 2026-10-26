import SwiftUI
import SwitchShelfDomain

struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                if model.isMultiSelection {
                    MultiSelectionInspector(model: model)
                        .padding(18)
                } else if let game = model.activeGame {
                    GameInspector(model: model, game: game)
                        .padding(18)
                } else {
                    emptyState
                }
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.inspector)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
        }
    }

    private var header: some View {
        HStack {
            Text("详情")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            Button {
                model.toggleInspector()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("隐藏检查器（⌘⌥I）")
            .accessibilityLabel("隐藏检查器")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.65))
                .frame(width: 62, height: 62)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("选择游戏查看详情")
                .font(.system(size: 13, weight: .semibold))
            Text("本地内容、保守的安装状态与访达操作会显示在这里。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
        .padding(.horizontal, 24)
    }
}

private struct GameInspector: View {
    @Bindable var model: AppModel
    var game: Game

    private var assessment: InstallationAssessment { model.assessment(for: game) }
    private var gameSources: [LibrarySource] { model.sources(for: game) }
    private var inPlan: Bool { model.isInPlan(game.id) }

    private var groupedContents: [(kind: ContentKind, contents: [LocalContent])] {
        ContentKind.allCases.compactMap { kind in
            let contents = game.contents.filter { $0.kind == kind }
                .sorted { $0.fileURL.lastPathComponent.localizedStandardCompare($1.fileURL.lastPathComponent) == .orderedAscending }
            return contents.isEmpty ? nil : (kind, contents)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CoverArtwork(game: game, cornerRadius: 16)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 300)
                .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 5) {
                Text(game.title)
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let original = game.originalTitle, original != game.title {
                    Text(original)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 5) {
                    BadgePill(
                        text: game.identification.label,
                        systemImage: game.identification.isPending ? "questionmark" : "checkmark",
                        tone: game.identification.isPending ? .warning : .success
                    )
                    BadgePill(
                        text: assessment.state.label,
                        systemImage: assessment.state.symbol,
                        tone: assessmentTone
                    )
                    if !game.contents.isEmpty && game.contents.allSatisfy({ $0.availability == .offline }) {
                        BadgePill(text: "来源离线", systemImage: "wifi.slash", tone: .neutral)
                    }
                }
                .padding(.top, 2)
            }

            HStack(spacing: 14) {
                Label("\(game.contents.count) 个文件", systemImage: "doc.on.doc")
                Text(formatByteCount(game.byteCount))
                    .monospacedDigit()
                Text(game.contentSummary)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)

            assessmentCard

            if !game.contents.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("本地内容")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("本地只读")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(groupedContents, id: \.kind) { group in
                        HStack(spacing: 5) {
                            Image(systemName: group.kind.symbol)
                                .font(.system(size: 9, weight: .semibold))
                            Text(group.kind.label)
                            Text("×\(group.contents.count)")
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                        ForEach(group.contents) { content in
                            contentRow(content)
                        }
                    }
                }
            }

            if !gameSources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("所在来源")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(gameSources) { source in
                        HStack(spacing: 7) {
                            Image(systemName: "externaldrive.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(source.name).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Circle()
                                .fill(source.availability == .online ? Theme.installed : Theme.warning)
                                .frame(width: 5, height: 5)
                            Text(source.availability.label)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            Button("在访达中显示") { model.revealSource(source) }
                            Button("扫描此来源") { model.scanSource(source.id) }
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                if inPlan {
                    Button {
                        model.showQueue()
                    } label: {
                        Label("已加入安装队列 · 查看", systemImage: "checkmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityLabel("已在安装队列中，打开队列")
                } else {
                    Button {
                        model.addToQueue(game)
                    } label: {
                        Label("加入安装队列", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(game.contents.isEmpty)
                    .help(game.contents.isEmpty ? "该条目没有本地内容文件" : "把本地内容加入安装计划")
                    .accessibilityLabel("加入安装队列")
                }
                Button {
                    model.revealGame(game)
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(game.revealURL == nil)
                .help(game.revealURL == nil ? "该条目没有本地文件路径" : "在访达中定位基础内容文件")
            }
            .padding(.top, 2)

            Text("安装状态依据设备清单证据：只有本体正向记录才会显示已安装，缺失记录仅在清单完整时作为证据。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var assessmentTone: StatusTone {
        switch assessment.state {
        case .installed: .success
        case .partial: .warning
        case .notInstalled: .neutral
        case .unknown: .neutral
        }
    }

    private var assessmentCard: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: assessment.state.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(assessmentTone.color)
                .frame(width: 28, height: 28)
                .background(assessmentTone.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("安装状态")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let observed = assessment.observedAt {
                        Text("清单 \(relativeTime(observed))")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(assessment.state.label)
                    .font(.system(size: 12, weight: .semibold))
                Text(assessment.explanation)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(assessmentTone.soft.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(assessmentTone.color.opacity(0.16), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private func contentRow(_ content: LocalContent) -> some View {
        let state = model.assessment(for: content)
        return HStack(alignment: .top, spacing: 9) {
            ContentKindIcon(kind: content.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(content.displayVersion ?? formatVersion(content.rawVersion) ?? "版本未知")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                    Text(content.format.rawValue.uppercased())
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.hairline, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    if state.state == .installed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.installed)
                            .help("设备清单中存在匹配的 Title ID")
                    }
                    if content.availability == .offline {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.warning)
                            .help("来源离线")
                    }
                    Spacer(minLength: 0)
                    Text(formatByteCount(content.byteCount))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(content.fileURL.lastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let titleID = content.titleID {
                    Text(displayTitleID(titleID))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Button {
                model.revealInFinder(content.fileURL)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在访达中显示")
            .accessibilityLabel("在访达中显示 \(content.fileURL.lastPathComponent)")
        }
        .padding(9)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.6)
        }
        .contextMenu {
            Button("在访达中显示") { model.revealInFinder(content.fileURL) }
            Button("复制文件路径") { model.copyPath(content.fileURL) }
            if let titleID = content.titleID {
                Button("复制 Title ID") { model.copyTitleID(titleID) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(content.kind.label)，版本 \(content.displayVersion ?? formatVersion(content.rawVersion) ?? "未知")，\(formatByteCount(content.byteCount))")
    }
}

private struct MultiSelectionInspector: View {
    @Bindable var model: AppModel

    private var selected: [Game] { model.selectedGames }
    private var totalBytes: Int64 { selected.reduce(0) { $0 + $1.byteCount } }
    private var installedCount: Int {
        selected.filter { model.assessment(for: $0).state == .installed }.count
    }
    private var sourceNames: [String] {
        Array(Set(selected.flatMap { model.sources(for: $0).map(\.name) })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 46, height: 46)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selected.count) 款游戏已选择")
                        .font(.system(size: 15, weight: .semibold))
                    Text("批量操作仅影响本地安装计划")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                SummaryMetric(title: "本地内容", value: "\(selected.reduce(0) { $0 + $1.contents.count })")
                SummaryMetric(title: "占用", value: formatByteCount(totalBytes))
                SummaryMetric(title: "已安装", value: installedCount > 0 ? "\(installedCount)" : "—")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("游戏")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(selected.prefix(6)) { game in
                    HStack(spacing: 7) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                        Text(game.title).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(formatByteCount(game.byteCount))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                if selected.count > 6 {
                    Text("另有 \(selected.count - 6) 款游戏")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !sourceNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("来源")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(sourceNames.joined(separator: "、"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                Button {
                    model.addSelectedToQueue()
                } label: {
                    Label("全部加入安装队列", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("把 \(selected.count) 款游戏加入安装队列")

                Button("清除选择") { model.clearSelection() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 2)
        }
    }
}

private struct SummaryMetric: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.6)
        }
        .accessibilityElement(children: .combine)
    }
}
