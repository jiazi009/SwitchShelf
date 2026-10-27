import AppKit
import SwiftUI

enum Theme {
    static let controlHeight: CGFloat = 32
    static let accent = Color(red: 0.12, green: 0.39, blue: 0.96)
    static let accentDeep = Color(red: 0.08, green: 0.28, blue: 0.82)
    static let violet = Color(red: 0.48, green: 0.34, blue: 0.94)
    static let installed = Color(red: 0.10, green: 0.60, blue: 0.36)
    static let warning = Color(red: 0.90, green: 0.52, blue: 0.12)
    static let danger = Color(red: 0.84, green: 0.24, blue: 0.24)

    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let canvas = adaptive(
        light: NSColor(calibratedRed: 0.965, green: 0.971, blue: 0.982, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.100, alpha: 1)
    )
    static let inspector = adaptive(
        light: NSColor.white,
        dark: NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.135, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor.white,
        dark: NSColor(calibratedRed: 0.125, green: 0.137, blue: 0.160, alpha: 1)
    )
    static let surfaceAlt = adaptive(
        light: NSColor(calibratedRed: 0.925, green: 0.936, blue: 0.955, alpha: 1),
        dark: NSColor(calibratedRed: 0.155, green: 0.168, blue: 0.195, alpha: 1)
    )
    static let surfaceMuted = adaptive(
        light: NSColor(calibratedRed: 0.945, green: 0.953, blue: 0.968, alpha: 1),
        dark: NSColor(calibratedRed: 0.135, green: 0.147, blue: 0.170, alpha: 1)
    )
    static let hairline = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.085),
        dark: NSColor(calibratedWhite: 1, alpha: 0.10)
    )
    static let strongHairline = adaptive(
        light: NSColor(calibratedWhite: 0, alpha: 0.14),
        dark: NSColor(calibratedWhite: 1, alpha: 0.17)
    )
    static let sidebarText = adaptive(
        light: NSColor(calibratedWhite: 0.16, alpha: 1),
        dark: NSColor(calibratedWhite: 0.92, alpha: 1)
    )
}

enum StatusTone {
    case neutral, accent, success, warning, danger

    var color: Color {
        switch self {
        case .neutral: Color.secondary
        case .accent: Theme.accent
        case .success: Theme.installed
        case .warning: Theme.warning
        case .danger: Theme.danger
        }
    }

    var soft: Color { color.opacity(0.13) }

    /// Solid cover badges always carry white text, including in dark appearance.
    var solidFill: Color {
        switch self {
        case .neutral: Color(red: 0.20, green: 0.24, blue: 0.30)
        case .accent: Theme.accentDeep
        case .success: Color(red: 0.06, green: 0.43, blue: 0.25)
        case .warning: Color(red: 0.62, green: 0.32, blue: 0.07)
        case .danger: Theme.danger
        }
    }
}

struct WindowWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.canvas
            RadialGradient(
                colors: [Theme.accent.opacity(colorScheme == .dark ? 0.30 : 0.22), .clear],
                center: .topLeading,
                startRadius: 20,
                endRadius: 900
            )
            RadialGradient(
                colors: [Theme.violet.opacity(colorScheme == .dark ? 0.20 : 0.14), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 820
            )
            LinearGradient(
                colors: [Color.white.opacity(colorScheme == .dark ? 0.015 : 0.16), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

struct SidebarBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Theme.accent.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    Color.white.opacity(colorScheme == .dark ? 0.01 : 0.14),
                    Theme.violet.opacity(colorScheme == .dark ? 0.09 : 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ChromeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = NSColor(Theme.canvas)
        window?.isMovableByWindowBackground = true
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
    }
}

struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.8)
            }
    }
}
