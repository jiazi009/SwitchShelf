import AppKit
import Darwin
import SwiftUI
import ImageIO
import SwitchShelfDomain
import SwitchShelfLibrary

/// Compiled only by verify-ui-layout.sh --empty-library-window. The production
/// App/WindowGroup is retained, but bootstrap, defaults and storage are isolated.
extension AppModel {
    static func emptyLibraryWindowFixture() -> AppModel {
        DispatchQueue.global().asyncAfter(deadline: .now() + (CommandLine.arguments.contains("--live-staging") ? 150 : 35)) {
            FileHandle.standardError.write(Data("Window regression timed out\n".utf8))
            exit(2)
        }
        let model = AppModel()
        if CommandLine.arguments.contains("--live-staging") {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!)
            let source = LibrarySource(id: "live-fixture", url: root, name: "Synthetic only", availability: .offline)
            let games = (1...3).map { index in
                Game(id: "live-\(index)", title: "合成交互游戏 \(index)", contents: [
                    LocalContent(id: "live-file-\(index)", kind: .base,
                                 fileURL: root.appendingPathComponent("fixture-\(index).nsp"),
                                 byteCount: 3, format: .nsp, availability: .offline)
                ])
            }
            model.seedUIReview(LibrarySnapshot(sources: [source], games: games), plan: [], page: .all, layout: .grid, inspector: false)
        } else {
            model.seedUIReview(LibrarySnapshot(), plan: [], page: .all, layout: .grid, inspector: true)
        }
        return model
    }

    func runEmptyLibraryWindowRegression() async {
        if CommandLine.arguments.contains("--live-staging") {
            print("LIVE_STAGING_PID \(ProcessInfo.processInfo.processIdentifier); synthetic, disconnected, no installation allowed")
            fflush(stdout)
            try? await Task.sleep(for: .seconds(140))
            NSApp.terminate(nil)
            return
        }
        defer { UserDefaults(suiteName: "local.switchshelf.ui-review.fixture")?.removePersistentDomain(forName: "local.switchshelf.ui-review.fixture") }
        do {
            // A real display-cycle must run: offscreen layout alone did not reveal
            // the empty-library NSHostingView/NSWindow constraint feedback loop.
            for (width, height) in [(1516.0, 809.0), (1276, 1410), (960, 640), (1280, 820)] {
                guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
                    throw WindowRegressionFailure.missingWindow
                }
                window.setContentSize(NSSize(width: width, height: height))
                try await Task.sleep(for: .seconds(1))
                let actual = window.contentLayoutRect.size
                print("LAYOUT \(width)x\(height): \(WindowLayoutEvidence.frames)")
                for name in ["brand", "header", "installButton", "staging"] {
                    guard let frame = WindowLayoutEvidence.frames[name],
                          frame.minY >= 0, frame.maxY <= (window.contentView?.bounds.height ?? actual.height) else {
                        throw WindowRegressionFailure.clippedContent
                    }
                }
                if CommandLine.arguments.contains("--dump-layout"), let root = window.contentView {
                    WindowLayoutEvidence.dump(root, in: window)
                }
                guard actual.width.isFinite, actual.height.isFinite,
                      actual.width <= width + 2, actual.height <= height + 2 else {
                    FileHandle.standardError.write(Data("Requested \(width)x\(height), got \(actual.width)x\(actual.height)\n".utf8))
                    throw WindowRegressionFailure.unstableSize
                }
            }
            let source = LibrarySource(id: "window-fixture", url: URL(fileURLWithPath: NSTemporaryDirectory()),
                                       name: "Window fixture only", availability: .offline)
            let content = LocalContent(id: "window-fixture-base", kind: .base,
                                       fileURL: source.url.appendingPathComponent("window-fixture.nsp"),
                                       byteCount: 1, format: .nsp, availability: .offline)
            let game = Game(id: "window-fixture-game", title: "Window fixture only",
                            contents: [content], identification: .needsReview)
            seedUIReview(LibrarySnapshot(sources: [source], games: [game]), plan: [], page: .source(source.id), layout: .grid, inspector: true)
            try await Task.sleep(for: .seconds(1))
            removeSource(source)
            try await Task.sleep(for: .seconds(1))
            guard sources.isEmpty, games.isEmpty, selection == .all else {
                throw WindowRegressionFailure.removal
            }
            showDevice()
            try await Task.sleep(for: .seconds(1))
            showAllGames()
            try await Task.sleep(for: .seconds(1))
            try await runSelectionRegression(source: source)
            try await verifyCoverPreparation()
            try await runInstallStagingRegression()
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("passed".utf8).write(to: directory.appendingPathComponent("window-regression-passed"))
            print("PASS: production WindowGroup; visible header/brand, resize, source removal, selection modifiers and inspector reopening. No bootstrap, NAS, USB or installation.")
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("Window regression failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private func verifyCoverPreparation() async throws {
        guard let context = CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8,
                                      bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WindowRegressionFailure.cover
        }
        context.setFillColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            throw WindowRegressionFailure.cover
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WindowRegressionFailure.cover }
        let thumbnail = CoverThumbnail(pixelWidth: 960, pixelHeight: 640, jpegData: data as Data)
        let (prepared, ranOnMain) = await Task.detached {
            (PreparedCover.decode(thumbnail), pthread_main_np() != 0)
        }.value
        guard !ranOnMain, let prepared, prepared.image.width == 480, prepared.image.height == 320,
              prepared.palette.red > prepared.palette.green else { throw WindowRegressionFailure.cover }
        let invalid = CoverThumbnail(pixelWidth: 1, pixelHeight: 1, jpegData: Data([0xff]))
        guard PreparedCover.decode(invalid) == nil else { throw WindowRegressionFailure.cover }
        print("PASS: bounded background artwork decode and palette; invalid image rejected.")
    }

    private func runSelectionRegression(source: LibrarySource) async throws {
        let fixtures = (0..<1_000).map { index in
            Game(id: "perf-fixture-\(index)", title: String(format: "Fixture %04d", index), contents:
                (0..<12).map { part in
                    LocalContent(id: "perf-\(index)-\(part)", kind: part == 0 ? .base : .dlc,
                                 fileURL: source.url.appendingPathComponent("fixture-\(index)-\(part).nsp"),
                                 byteCount: 1, format: .nsp, availability: .offline)
                }, identification: .needsReview)
        }
        seedUIReview(LibrarySnapshot(sources: [source], games: fixtures), plan: [], page: .all, layout: .grid, inspector: false)
        sortOrder = .title
        let started = ProcessInfo.processInfo.systemUptime
        for game in fixtures.prefix(80) { handleGridTap(game, modifiers: []) }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print(String(format: "SELECTION_CPU_MS %.3f (80 plain selections, 1000 synthetic games / 12000 contents; not an FPS measurement)", milliseconds))
        let ordered = filteredGames
        handleGridTap(ordered[2], modifiers: [])
        handleGridTap(ordered[4], modifiers: .command)
        guard selectedGameIDs == [ordered[2].id, ordered[4].id] else { throw WindowRegressionFailure.selection }
        handleGridTap(ordered[7], modifiers: .shift)
        guard selectedGameIDs == Set(ordered[4...7].map(\.id)) else { throw WindowRegressionFailure.selection }
        clearSelection()
        closeGameDetails()
        try await Task.sleep(for: .milliseconds(300))
        handleGridTap(ordered[3], modifiers: [])
        guard detailGame == nil else { throw WindowRegressionFailure.selection }
        let staged = plan
        openGameDetails(ordered[3])
        try await Task.sleep(for: .milliseconds(400))
        guard detailGame?.id == ordered[3].id, plan == staged else { throw WindowRegressionFailure.selection }
        closeGameDetails()
        try await Task.sleep(for: .milliseconds(300))
        guard detailGame == nil, plan == staged else { throw WindowRegressionFailure.selection }
        for name in ["brand", "header"] {
            guard let frame = WindowLayoutEvidence.frames[name], frame.minY >= 0 else {
                throw WindowRegressionFailure.clippedContent
            }
        }
    }
}

@MainActor
enum WindowLayoutEvidence {
    static var frames: [String: CGRect] = [:]
    static func press(_ frame: CGRect, in window: NSWindow) throws {
        let height = window.contentView?.bounds.height ?? window.frame.height
        let point = NSPoint(x: frame.midX, y: height - frame.midY)
        window.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else {
                throw NSError(domain: "NativeFixtureEvent", code: 1)
            }
            NSApp.sendEvent(event)
        }
    }
    static func dump(_ view: NSView, in window: NSWindow, depth: Int = 0) {
        guard depth < 10 else { return }
        print(String(repeating: " ", count: depth) + "\(type(of: view)) frame=\(view.convert(view.bounds, to: nil)) visible=\(view.visibleRect)")
        for child in view.subviews { dump(child, in: window, depth: depth + 1) }
    }
}

private enum WindowRegressionFailure: Error {
    case missingWindow, unstableSize, removal, clippedContent, selection, cover
}
