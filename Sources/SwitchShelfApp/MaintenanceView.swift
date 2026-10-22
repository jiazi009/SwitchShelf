import SwiftUI
import SwitchShelfDomain

struct MaintenanceView: View {
    @Bindable var model: AppModel
    @State private var cacheSize = "—"

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice {
                        NoticeBanner(notice: notice) { model.perform($0) } onDismiss: { model.notice = nil }
                    }
                    statsGrid
                    cacheCard
                    sourcesCard
                    issuesCard
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.canvas)
        .task(id: model.lastScanDate) {
            let bytes = await model.cacheByteCount()
            cacheSize = bytes > 0 ? formatByteCount(bytes) : "未生成"
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PageHeading(title: "维护", subtitle: model.pageSubtitle)
            Spacer()
            Button {
                model.refreshAvailability()
            } label: {
                Label("刷新来源状态", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.glass)
            .accessibilityLabel("刷新来源可用状态")

            Button {
                model.scanAll()
            } label: {
                Label("全部扫描", systemImage: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.glass)
            .disabled(model.isScanning || model.sources.isEmpty)
            .help("重新扫描全部来源（⌘R）")
            .accessibilityLabel("重新扫描全部来源")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private static let statColumns = Array(
        repeating: GridItem(.flexible(minimum: 150), spacing: 10),
        count: 3
    )

    private var statsGrid: some View {
        LazyVGrid(columns: Self.statColumns, spacing: 10) {
            StatTile(
                title: "游戏",
                value: "\(model.games.count)",
                detail: "\(model.totalContentCount) 个本地内容",
                symbol: "gamecontroller.fill"
            )
            StatTile(
                title: "来源",
                value: "\(model.onlineSourceCount)/\(model.sourceCount) 在线",
                detail: model.offlineSources.isEmpty ? "全部来源可访问" : "\(model.offlineSources.count) 个离线，缓存保留",
                symbol: "externaldrive.fill",
                tone: model.offlineSources.isEmpty ? .accent : .warning
            )
            StatTile(
                title: "本地缓存",
                value: model.cacheLoaded ? "已载入" : "未载入",
                detail: cacheSize,
                symbol: "internaldrive.fill",
                tone: model.cacheLoaded ? .success : .neutral
            )
            StatTile(
                title: "最后扫描",
                value: relativeTime(model.lastScanDate),
                detail: absoluteTime(model.lastScanDate),
                symbol: "clock.fill",
                tone: .neutral
            )
            StatTile(
                title: "安装队列",
                value: "\(model.plan.count) 项",
                detail: formatByteCount(model.planTotalBytes),
                symbol: "arrow.up.arrow.down.circle.fill"
            )
            StatTile(
                title: "设备清单",
                value: model.inventory.map { "\($0.records.count) 条" } ?? "未读取",
                detail: model.inventory.map { "\($0.isComplete ? "完整" : "不完整") · 本地匹配 \(model.installedGameCount)" } ?? "连接后手动读取",
                symbol: "list.bullet.rectangle.portrait",
                tone: model.inventory == nil ? .neutral : (model.inventory?.isComplete == true ? .success : .warning)
            )
        }
    }

    private var cacheCard: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "cylinder.split.1x2")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("本地数据")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Button("复制诊断摘要") { model.copyDiagnostics() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("复制诊断摘要")
                }
                Text(model.appDataPath)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text("缓存数据库与安装计划存放在 Application Support/SwitchShelf；游戏来源始终只读。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("在访达中显示缓存") { model.revealCache() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("在访达中显示缓存数据库")
                    Button("打开应用数据目录") { model.openAppSupport() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("打开应用数据目录")
                }
            }
        }
    }

    private var sourcesCard: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("来源状态")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(model.sourceCount) 个来源")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                if model.sources.isEmpty {
                    Text("尚未添加来源。").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources) { source in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(source.availability == .online ? Theme.installed : Theme.warning)
                                .frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                Text(source.url.path)
                                    .font(.system(size: 8.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(source.availability.label)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Button("扫描") { model.scanSource(source.id) }
                                .buttonStyle(.plain)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accent)
                                .disabled(model.isScanning)
                                .accessibilityLabel("扫描来源 \(source.name)")
                            Button {
                                model.revealSource(source)
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, height: 20)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("在访达中显示来源 \(source.name)")
                        }
                        .padding(.vertical, 3)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
    }

    private var issuesCard: some View {
        SurfaceCard(padding: 16) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("扫描问题")
                        .font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Text("\(model.scanIssues.count) 条")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                if model.scanIssues.isEmpty {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.installed)
                        Text("当前缓存中没有记录扫描问题。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(model.scanIssues.enumerated()), id: \.offset) { _, issue in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.warning)
                                .padding(.top, 1)
                            Text(issue)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}
