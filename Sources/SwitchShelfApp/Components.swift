import AppKit
import SwiftUI
import SwitchShelfDomain

extension AppNotice.Level {
    var tone: StatusTone {
        switch self {
        case .info: .accent
        case .warning: .warning
        case .error: .danger
        }
    }

    var symbol: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

extension DeviceConnectionState {
    var label: String {
        switch self {
        case .disconnected: "未检测到设备"
        case .detected: "已检测到 USB 设备"
        case .waitingForMTP: "等待 MTP 响应"
        case .ready: "MTP 已连接"
        case .reading: "正在读取"
        case .busy: "设备忙碌"
        case .error: "连接错误"
        }
    }

    var tone: StatusTone {
        switch self {
        case .disconnected: .neutral
        case .detected, .waitingForMTP: .warning
        case .ready: .success
        case .reading: .accent
        case .busy: .warning
        case .error: .danger
        }
    }

    var symbol: String {
        switch self {
        case .disconnected: "cable.connector"
        case .detected: "cable.connector.horizontal"
        case .waitingForMTP: "ellipsis.circle"
        case .ready: "checkmark.circle.fill"
        case .reading: "arrow.triangle.2.circlepath"
        case .busy: "hourglass"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

struct BadgePill: View {
    var text: String
    var systemImage: String?
    var tone: StatusTone = .neutral
    var solid = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(solid ? .white : tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(solid ? tone.color : tone.soft, in: Capsule())
        .overlay {
            if !solid {
                Capsule().strokeBorder(tone.color.opacity(0.22), lineWidth: 0.6)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .accessibilityAddTraits(.isHeader)
    }
}

struct PageHeading: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 26, weight: .bold, design: .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

struct NoticeBanner: View {
    var notice: AppNotice
    var onAction: (AppNotice.Action) -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.level.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(notice.level.tone.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(notice.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if let action = notice.action, let label = notice.actionLabel {
                Button(label) { onAction(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(label)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(notice.level.tone.soft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(notice.level.tone.color.opacity(0.20), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
    }
}

struct DeviceStatusPill: View {
    var discovery: DeviceDiscovery?
    var isDiscovering: Bool
    var action: () -> Void

    private var state: DeviceConnectionState { discovery?.state ?? .disconnected }
    private var label: String {
        if isDiscovering { return "正在检测设备" }
        guard discovery != nil else { return "设备未检测" }
        switch state {
        case .disconnected: return "未连接 Switch"
        case .detected, .waitingForMTP: return "Switch · 等待 MTP"
        case .ready: return "Switch · 已就绪"
        case .reading: return "Switch · 读取中"
        case .busy: return "Switch · 忙碌"
        case .error: return "Switch · 连接错误"
        }
    }
    private var tone: StatusTone { isDiscovering ? .accent : (discovery == nil ? .neutral : state.tone) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isDiscovering || state == .reading {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else {
                    Circle().fill(tone.color).frame(width: 6, height: 6)
                }
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.sidebarText.opacity(0.5))
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.hairline, lineWidth: 0.7)
        }
        .help("打开“我的 Switch”查看设备与 MTP 说明")
        .accessibilityLabel("设备状态：\(label)")
    }
}

struct InspectorToggleButton: View {
    var isPresented: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.sidebarText.opacity(0.75))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.7)
        }
        .help(isPresented ? "隐藏检查器（⌘⌥I）" : "显示检查器（⌘⌥I）")
        .accessibilityLabel(isPresented ? "隐藏检查器" : "显示检查器")
    }
}

struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent.opacity(0.8))
                .frame(width: 62, height: 62)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var detail: String? = nil
    var symbol: String
    var tone: StatusTone = .accent

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 30, height: 30)
                .background(tone.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.8)
        }
        .accessibilityElement(children: .combine)
    }
}

struct InlineErrorText: View {
    var text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Theme.danger)
    }
}
