import AppKit
import Darwin
import SwiftUI
import SwitchShelfDomain

/// Uses the actual production views, never the production App entry point.
/// Generated artwork and every library/device value below are UI fixtures.
@main
struct UIReviewLayout {
    @MainActor
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("UI fixture layout validation failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func run() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporary = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
        let fixtures = try makeFixtures(in: temporary)
        let fixtureDefaults = UserDefaults(suiteName: "local.switchshelf.ui-review.fixture")!
        defer { fixtureDefaults.removePersistentDomain(forName: "local.switchshelf.ui-review.fixture") }
        if CommandLine.arguments.contains("--live-dark") {
            showLiveDark(fixtures, defaults: fixtureDefaults)
            return
        }
        var captures = [[String: Any]]()

        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            application.appearance = appearance
            for width in [960, 1280] {
                let size = NSSize(width: width, height: width == 960 ? 640 : 820)
                for scenario in ["grid", "list", "queue", "maintenance", "device"] {
                    let model = AppModel()
                    let page: SidebarItem = scenario == "queue" ? .queue
                        : scenario == "maintenance" ? .maintenance
                        : scenario == "device" ? .device : .all
                    model.seedUIReview(fixtures, plan: fixtures.games.prefix(2).map {
                        PlanItem(game: $0, note: "UI fixture：很长的本地计划备注，用于确认窗口变窄后文字和按钮不会挤出卡片。")
                    }, page: page, layout: scenario == "list" ? .list : .grid, inspector: width >= 1280)
                    let view = RootView(model: model)
                        .environment(\.installationAnimationsEnabled, !CommandLine.arguments.contains("--reduce-motion"))
                        .environment(\.colorScheme, scheme)
                        .defaultAppStorage(fixtureDefaults)
                    let name = "\(scenario)-\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")"
                    captures.append(try render(view, size: size, appearance: appearance, name: name, output: output))
                }
            }
            let compact = AppModel()
            compact.seedUIReview(fixtures, plan: [], page: .all, layout: .grid, inspector: false)
            compact.coverSize = 120
            captures.append(try render(RootView(model: compact).environment(\.colorScheme, scheme)
                .defaultAppStorage(fixtureDefaults), size: NSSize(width: 960, height: 640), appearance: appearance,
                name: "grid-compact120-960x640-\(dark ? "dark" : "light")", output: output))
            let settings = SettingsView().environment(\.colorScheme, scheme).defaultAppStorage(fixtureDefaults)
            captures.append(try render(settings, size: NSSize(width: 520, height: 440), appearance: appearance,
                name: "settings-\(dark ? "dark" : "light")", output: output))
        }
        let manifest: [String: Any] = [
            "fixtureOnly": true,
            "productionSources": true,
            "captureMethod": "NSHostingView.cacheDisplay (offscreen)",
            "limitations": [
                "Native materials, menu/button foreground colors, and dynamic NSColor/inspector colors are not faithfully represented by offscreen cacheDisplay; verify in the live app.",
                "The unbundled harness has a generic app icon; app icon correctness is verified in the packaged app.",
                "Fixtures are synthetic; these captures do not establish NAS, USB, package identity, or installation behavior."
            ],
            "noBootstrapUSBOrInstall": true,
            "captures": captures
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("manifest.json"))
        print("Rendered \(captures.count) production-view fixture layouts at \(output.path)")
    }

    @MainActor
    static func makeFixtures(in temporary: URL) throws -> LibrarySnapshot {
        let source = temporary.appendingPathComponent("fixture-library", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let titles = [
            "UI fixture：漫长的游戏名称——用于验证两行封面标题、完整详情和紧凑列表布局",
            "UI fixture：方形封面",
            "UI fixture：缺少封面",
            "UI fixture：离线来源与待确认身份"
        ]
        var games = [Game]()
        for index in titles.indices {
            let coverURL = index == 2 ? nil : source.appendingPathComponent("cover-\(index).png")
            if let coverURL {
                let image = NSImage(size: NSSize(width: 256, height: 256))
                image.lockFocus()
                let hue = CGFloat(index) / 4
                NSColor(calibratedHue: hue, saturation: 0.7, brightness: 0.8, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 256, height: 256)).fill()
                NSColor.white.withAlphaComponent(0.5).setFill()
                NSBezierPath(ovalIn: NSRect(x: 56, y: 56, width: 144, height: 144)).fill()
                let label = "UI FIXTURE \(index + 1)" as NSString
                label.draw(at: NSPoint(x: 24, y: 112), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.black])
                image.unlockFocus()
                let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try representation.representation(using: .png, properties: [:])!.write(to: coverURL)
            }
            let contents = [LocalContent(id: "fixture-\(index)-base", kind: .base,
                fileURL: source.appendingPathComponent("fixture-game-\(index).nsp"), byteCount: 1_500_000_000,
                format: .nsp, availability: index == 3 ? .offline : .online)]
            games.append(Game(id: "fixture-game-\(index)", title: titles[index], coverURL: coverURL,
                contents: contents, identification: .needsReview))
        }
        return LibrarySnapshot(sources: [LibrarySource(id: "fixture-source", url: source,
            name: "UI fixture：长来源名称用于检查侧栏和详情布局", availability: .offline)],
            games: games, scannedAt: Date(), issues: ["UI fixture：离线来源展示上次缓存，不代表真实 NAS 状态。"])
    }

    @MainActor
    static func showLiveDark(_ fixtures: LibrarySnapshot, defaults: UserDefaults) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let model = AppModel()
        model.seedUIReview(fixtures, plan: [], page: .all, layout: .grid, inspector: true)
        let root = RootView(model: model).preferredColorScheme(.dark).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: root)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "SwitchShelf UI fixture — dark (synthetic data only)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        let delegate = FixtureWindowDelegate()
        window.delegate = delegate
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("Live dark fixture window; pid=\(ProcessInfo.processInfo.processIdentifier). Close the window to exit. No bootstrap, scan, USB or installation is run.")
        withExtendedLifetime((window, delegate)) { NSApp.run() }
    }

    @MainActor
    static func render<V: View>(_ content: V, size: NSSize, appearance: NSAppearance,
                                name: String, output: URL) throws -> [String: Any] {
        print("Rendering fixture: \(name)")
        fflush(stdout)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Run SwiftUI tasks (only local fixture cover loads and harmless layout callbacks).
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "UIReview", code: 1, userInfo: [NSLocalizedDescriptionKey: "No bitmap for \(name)"])
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "UIReview", code: 2, userInfo: [NSLocalizedDescriptionKey: "No PNG for \(name)"])
        }
        try data.write(to: output.appendingPathComponent(name + ".png"))
        let actual = host.bounds.size
        precondition(abs(actual.width - size.width) < 1 && abs(actual.height - size.height) < 1,
                     "Unexpected host dimensions: \(name) \(actual)")
        let result: [String: Any] = ["name": name, "width": actual.width, "height": actual.height,
            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "pngBytes": data.count]
        window.contentView = nil
        window.close()
        return result
    }
}

@MainActor
private final class FixtureWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { NSApp.stop(nil) }
}
