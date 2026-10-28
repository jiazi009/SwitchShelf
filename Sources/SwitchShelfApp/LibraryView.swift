import SwiftUI
import SwitchShelfDomain

struct LibraryView: View {
    @Bindable var model: AppModel
    let installationMotion: Namespace.ID
    @FocusState private var searchFocused: Bool
    @State private var showIssues = false
    @State private var showCoverSlider = false

    private let gridPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
        }
        // Native split panes must be compressible; otherwise their ideal empty
        // height can exceed the actual window and center the toolbar offscreen.
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(Theme.canvas)
        .task(id: model.searchFocusToken) {
            guard model.searchFocusToken > 0 else { return }
            try? await Task.sleep(for: .milliseconds(40))
            searchFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    PageHeading(title: model.pageTitle, subtitle: model.pageSubtitle)
                    Spacer(minLength: 8)
                    headerActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    PageHeading(title: model.pageTitle, subtitle: model.pageSubtitle)
                    HStack { Spacer(minLength: 0); headerActions }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    searchField.frame(minWidth: 200, idealWidth: 280, maxWidth: 420)
                    filterControls
                    layoutControls
                }
                VStack(spacing: 10) {
                    searchField
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            filterControls
                            Spacer(minLength: 0)
                            layoutControls
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            filterControls
                            layoutControls
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            addFolderButton
            DeviceStatusPill(
                discovery: model.deviceDiscovery,
                isDiscovering: model.isDiscovering,
                isReadingInventory: model.isReadingInventory
            ) { model.select(.device) }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var filterControls: some View {
        HStack(spacing: 8) {
            contentMenu
            installMenu
            sortMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var layoutControls: some View {
        HStack(spacing: 8) {
            layoutSwitch
            if model.layout == .grid { coverSizeButton }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var addFolderButton: some View {
        Button {
            model.chooseFolder()
        } label: {
            Label("添加文件夹", systemImage: "folder.badge.plus")
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 2)
                .frame(height: 20)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .tint(Theme.accent)
        .controlSize(.large)
        .frame(height: Theme.controlHeight)
        .help("添加包含游戏文件的文件夹（⌘O）")
        .accessibilityLabel("添加文件夹来源")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("搜索游戏、文件名或 Title ID", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .accessibilityLabel("搜索游戏、文件名或 Title ID")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: Theme.controlHeight)
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                searchFocused ? Theme.accent.opacity(0.55) : Theme.hairline,
                lineWidth: searchFocused ? 1.1 : 0.7
            )
        }
        .opacity(searchFocused ? 1 : 0.96)
    }

    private var contentMenu: some View {
        Menu {
            Picker("内容类型", selection: $model.contentFilter) {
                ForEach(ContentFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            FilterPillLabel(text: model.contentFilter.label)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(.primary)
        .frame(height: Theme.controlHeight)
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.hairline, lineWidth: 0.7)
        }
        .help("按本地内容类型筛选")
        .accessibilityLabel("内容类型筛选，当前\(model.contentFilter.label)")
    }

    private var installMenu: some View {
        Menu {
            Picker("安装状态", selection: $model.installFilter) {
                ForEach(InstallFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.inline)
        } label: {
            FilterPillLabel(text: model.installFilter == .all ? "全部状态" : model.installFilter == .installed ? "设备已安装" : "未确认")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(.primary)
        .frame(height: Theme.controlHeight)
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.hairline, lineWidth: 0.7)
        }
        .help("设备已安装包含已安装和部分安装。文件名已匹配的游戏按 Title ID 与内容类型对照当前清单，不是包字节验证。")
        .accessibilityLabel("安装状态筛选，当前\(model.installFilter.label)")
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $model.sortOrder) {
                ForEach(SortOrder.allCases) { order in
                    Text(order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            FilterPillLabel(text: model.sortOrder.label)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(.primary)
        .frame(height: Theme.controlHeight)
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.hairline, lineWidth: 0.7)
        }
        .help("游戏排序方式")
        .accessibilityLabel("排序方式，当前\(model.sortOrder.label)")
    }

    private var layoutSwitch: some View {
        HStack(spacing: 2) {
            layoutButton(.grid)
            layoutButton(.list)
        }
        .padding(3)
        .frame(height: Theme.controlHeight)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视图模式")
    }

    private func layoutButton(_ layout: LibraryLayout) -> some View {
        Button {
            model.layout = layout
        } label: {
            Image(systemName: layout.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.layout == layout ? Color.white : Theme.sidebarText.opacity(0.7))
                .frame(width: 28, height: Theme.controlHeight - 6)
                .background {
                    if model.layout == layout {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(layout.label)视图（⌘\(layout == .grid ? "1" : "2")）")
        .accessibilityLabel("\(layout.label)视图")
        .accessibilityAddTraits(model.layout == layout ? .isSelected : [])
    }

    private var coverSizeButton: some View {
        Button {
            showCoverSlider.toggle()
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.sidebarText.opacity(0.75))
                .frame(width: Theme.controlHeight, height: Theme.controlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.7)
        }
        .help("调整封面尺寸")
        .accessibilityLabel("调整封面尺寸，当前 \(Int(model.coverSize)) 点")
        .popover(isPresented: $showCoverSlider, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("封面尺寸").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(Int(model.coverSize)) 点")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $model.coverSize, in: 120...240, step: 4) {
                    Text("封面尺寸")
                } minimumValueLabel: {
                    Image(systemName: "square.grid.3x3").font(.system(size: 9))
                } maximumValueLabel: {
                    Image(systemName: "square.grid.2x2").font(.system(size: 9))
                }
                .accessibilityLabel("封面尺寸")
                .accessibilityValue("\(Int(model.coverSize)) 点")
                HStack {
                    Text("紧凑").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Spacer()
                    Text("宽松").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .padding(14)
            .frame(width: 230)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                NoticeBanner(notice: notice) { model.perform($0) } onDismiss: { model.notice = nil }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }
            if !model.offlineSources.isEmpty {
                offlineBanner
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
            }
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if !model.isBootstrapped {
            loadingState
        } else if model.filteredGames.isEmpty {
            emptyState
        } else if model.layout == .grid {
            gridContent
        } else {
            listContent
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在载入本地游戏库…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isScanning, model.games.isEmpty {
            VStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                VStack(spacing: 4) {
                    Text(model.scanPhase.map { "正在扫描「\($0)」…" } ?? "正在扫描来源…")
                        .font(.system(size: 14, weight: .semibold))
                    Text("首次扫描 SMB 来源可能需要一段时间。界面保持可用，缓存与队列不会受影响。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.games.isEmpty {
            if model.sources.isEmpty {
                EmptyStateView(
                    symbol: "folder.badge.plus",
                    title: "还没有游戏来源",
                    message: "添加包含 NSP、XCI、NSZ 或 XCZ 的文件夹。文件只会被只读扫描，不会被修改。",
                    actionTitle: "添加文件夹…",
                    action: { model.chooseFolder() }
                )
            } else if model.offlineSources.count == model.sources.count {
                EmptyStateView(
                    symbol: "externaldrive.badge.exclamationmark",
                    title: "来源当前离线",
                    message: "重新挂载「\(model.offlineSources.first?.name ?? "来源")」后刷新来源状态或重新扫描。离线不会清除已有缓存条目。",
                    actionTitle: "刷新来源状态",
                    action: { model.refreshAvailability() }
                )
            } else {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "尚未发现游戏",
                    message: "来源中还没有可识别的 NSP、XCI、NSZ 或 XCZ 文件。可以重新扫描，或检查文件夹是否挂载正确。",
                    actionTitle: "重新扫描来源",
                    action: { model.scanAll() }
                )
            }
        } else if model.hasActiveFilters {
            EmptyStateView(
                symbol: "line.3.horizontal.decrease.circle",
                title: "没有匹配的游戏",
                    message: "当前搜索、内容类型或安装状态筛选没有结果。设备已安装包含已安装和部分安装，且只使用当前清单里的本体 Title ID。",
                actionTitle: "清除搜索与筛选",
                action: { model.clearFilters() }
            )
        } else if model.selection == .recent {
            EmptyStateView(
                symbol: "clock",
                title: "最近没有新游戏",
                message: "最近 30 天内没有首次在本机发现的游戏。进入“全部游戏”查看缓存条目。",
                actionTitle: "查看全部游戏",
                action: { model.showAllGames() }
            )
        } else if model.selection == .unidentified {
            EmptyStateView(
                symbol: "checkmark.seal",
                title: "没有待识别游戏",
                message: "当前缓存条目的身份证据都已被标记为已验证或已匹配。"
            )
        } else {
            EmptyStateView(
                symbol: "tray",
                title: "此来源没有游戏",
                message: "来源可能为空、离线，或仍在使用上次扫描结果。可以重新扫描此来源。",
                actionTitle: "重新扫描",
                action: { model.scanAll() }
            )
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: model.coverSize, maximum: model.coverSize + 36),
                        spacing: 20,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(model.filteredGames) { game in
                    GameCard(
                        model: model,
                        game: game,
                        isSelected: model.isInPlan(game.id),
                        installationMotion: installationMotion
                    )
                }
            }
            .padding(.horizontal, gridPadding)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.automatic)
        .accessibilityLabel("游戏封面网格")
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(model.filteredGames) { game in
                    GameListRow(model: model, game: game, isSelected: model.isInPlan(game.id),
                                installationMotion: installationMotion)
                }
            }
            .padding(16)
        }
        .accessibilityLabel("游戏列表")
    }

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.warning)
            Text(offlineMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("刷新状态") { model.refreshAvailability() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("刷新来源可用状态")
            Button("重新扫描") { model.scanAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .disabled(model.isScanning)
                .accessibilityLabel("重新扫描全部来源")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.18), lineWidth: 0.7)
        }
    }

    private var offlineMessage: String {
        if model.offlineSources.count == 1, let source = model.offlineSources.first {
            return "「\(source.name)」当前离线，正在显示上次扫描的缓存条目。"
        }
        return "\(model.offlineSources.count) 个来源当前离线，正在显示上次扫描的缓存条目。"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.filteredGames.count) 款游戏")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            if model.hasActiveFilters {
                Text("（全部 \(model.games.count)）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            if !model.plan.isEmpty {
                Text("· 待安装 \(model.plan.count) 款")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text(model.scanPhase.map { "正在扫描「\($0)」…" } ?? "正在扫描…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(model.lastScanDate == nil ? "尚未扫描" : "上次扫描 \(relativeTime(model.lastScanDate))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if !model.scanIssues.isEmpty {
                Button {
                    showIssues.toggle()
                } label: {
                    Label("\(model.scanIssues.count) 条问题", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看 \(model.scanIssues.count) 条扫描问题")
                .popover(isPresented: $showIssues, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("扫描问题")
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                                Button("复制诊断") { model.copyDiagnostics() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.accent)
                            }
                            ForEach(Array(model.scanIssues.enumerated()), id: \.offset) { _, issue in
                                Text(issue)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(14)
                    }
                    .frame(width: 360, height: 240)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 36)
        .background(Theme.canvas)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}

struct FilterPillLabel: View {
    var text: String

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Theme.sidebarText.opacity(0.55))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: Theme.controlHeight)
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
    }
}
