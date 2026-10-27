import AppKit
import SwiftUI
import SwitchShelfDomain

/// Compiled only by verify-ui-layout.sh --empty-library-window. The production
/// App/WindowGroup is retained, but bootstrap, defaults and storage are isolated.
extension AppModel {
    static func emptyLibraryWindowFixture() -> AppModel {
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("Window regression timed out\n".utf8))
            exit(2)
        }
        let model = AppModel()
        model.seedUIReview(LibrarySnapshot(), plan: [], page: .all, layout: .grid, inspector: true)
        return model
    }

    func runEmptyLibraryWindowRegression() async {
        defer { UserDefaults(suiteName: "local.switchshelf.ui-review.fixture")?.removePersistentDomain(forName: "local.switchshelf.ui-review.fixture") }
        do {
            // A real display-cycle must run: offscreen layout alone did not reveal
            // the empty-library NSHostingView/NSWindow constraint feedback loop.
            for (width, height) in [(1276.0, 1410.0), (960, 640), (1280, 820)] {
                guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
                    throw WindowRegressionFailure.missingWindow
                }
                window.setContentSize(NSSize(width: width, height: height))
                try await Task.sleep(for: .seconds(1))
                let actual = window.contentLayoutRect.size
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
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("passed".utf8).write(to: directory.appendingPathComponent("window-regression-passed"))
            print("PASS: real production WindowGroup; empty startup, resize, source removal and return to empty library. No bootstrap, NAS, USB or installation.")
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("Window regression failed: \(error)\n".utf8))
            exit(1)
        }
    }
}

private enum WindowRegressionFailure: Error {
    case missingWindow, unstableSize, removal
}
