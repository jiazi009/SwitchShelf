import SwiftUI
import SwitchShelfDomain

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            brand
                .padding(.horizontal, 14)
                .padding(.top, 44)
                .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    librarySection
                    manageSection
                    sourcesSection
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)

            scanFooter
            footer
        }
        // Allow NSSplitView to fit the viewport, rather than its ideal height.
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(SidebarBackground())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
        }
    }

    private var brand: some View {
        HStack(spacing: 9) {
            AppBrandIcon()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("SwitchShelf")
                    .font(.system(size: 15, weight: .bold))
                Text("本地游戏库")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("SwitchShelf 本地游戏库")
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "游戏库")
            SidebarRow(
                title: "全部游戏",
                systemImage: "square.grid.2x2.fill",
                count: model.count(for: .all),
                isSelected: model.selection == .all
            ) { model.select(.all) }
            SidebarRow(
                title: "最近添加",
                systemImage: "clock.fill",
                count: model.count(for: .recent),
                isSelected: model.selection == .recent
            ) { model.select(.recent) }
            SidebarRow(
                title: "待识别",
                systemImage: "questionmark.circle.fill",
                count: model.count(for: .unidentified),
                isSelected: model.selection == .unidentified
            ) { model.select(.unidentified) }
        }
    }

    private var manageSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "管理")
            SidebarRow(
                title: "我的 Switch",
                systemImage: "cable.connector",
                count: nil,
                isSelected: model.selection == .device,
                statusColor: deviceDot
            ) { model.select(.device) }
            SidebarRow(
                title: "无线连接",
                systemImage: "wifi",
                count: nil,
                isSelected: model.selection == .wifi,
                statusColor: wifiDot
            ) { model.select(.wifi) }
            SidebarRow(
                title: "文件管理",
                systemImage: "folder",
                count: nil,
                isSelected: model.selection == .files
            ) { model.select(.files) }
            SidebarRow(
                title: "相册截图",
                systemImage: "photo.on.rectangle.angled",
                count: nil,
                isSelected: model.selection == .album
            ) { model.select(.album) }
            SidebarRow(
                title: "维护",
                systemImage: "wrench.and.screwdriver.fill",
                count: nil,
                isSelected: model.selection == .maintenance
            ) { model.select(.maintenance) }
        }
    }

    private var deviceDot: Color? {
        guard let state = model.deviceDiscovery?.state else { return nil }
        return state.tone.color
    }

    private var wifiDot: Color? {
        switch model.wifi.phase {
        case .disconnected: nil
        case .connecting: Theme.accent
        case .connected: Theme.installed
        case .failed: Theme.danger
        case .unknown: Theme.warning
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(text: "来源")
            ForEach(model.sources) { source in
                SidebarRow(
                    title: source.name,
                    systemImage: "externaldrive.fill",
                    count: model.sourceGameCount(source.id),
                    isSelected: model.selection == .source(source.id),
                    statusColor: availabilityColor(source.availability)
                ) {
                    model.select(.source(source.id))
                }
                .contextMenu {
                    Button("扫描此来源") { model.scanSource(source.id) }
                        .disabled(model.isScanning)
                    Button("在访达中显示") { model.revealSource(source) }
                    Divider()
                    Button("移除此来源…", role: .destructive) {
                        model.sourcePendingRemoval = source
                    }
                }
                .help("\(source.url.path) · \(source.availability.label)")
            }

            Button {
                model.chooseFolder()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 17)
                    Text("添加文件夹…")
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加游戏文件夹来源")
            .help("添加包含 NSP、XCI、NSZ 或 XCZ 的文件夹（⌘O）")

            if model.sources.isEmpty {
                Text("尚未添加来源")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
        }
    }

    private var scanFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider().overlay(Theme.hairline)
            if model.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                    Text(model.scanPhase.map { "正在扫描「\($0)」…" } ?? "正在扫描…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: model.offlineSources.isEmpty ? "clock" : "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(model.offlineSources.isEmpty ? Color.secondary : Theme.warning)
                    Text(model.offlineSources.isEmpty
                         ? (model.lastScanDate == nil ? "尚未扫描" : "上次扫描 \(relativeTime(model.lastScanDate))")
                         : "\(model.offlineSources.count) 个来源离线 · 保留缓存")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 17)
                    Text("设置")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开设置")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    private func availabilityColor(_ availability: SourceAvailability) -> Color {
        switch availability {
        case .online: Theme.installed
        case .offline: Theme.warning
        case .unknown: Color.secondary.opacity(0.5)
        }
    }
}

struct SidebarRow: View {
    var title: String
    var systemImage: String
    var count: Int?
    var isSelected: Bool
    var statusColor: Color? = nil
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let statusColor {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.85) : statusColor)
                        .frame(width: 5.5, height: 5.5)
                        .accessibilityLabel("来源状态")
                }
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.accent : (isHovering ? Color.primary.opacity(0.055) : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .accessibilityLabel(title)
        .accessibilityValue(count.map { "\($0) 项" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
