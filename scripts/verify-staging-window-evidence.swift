import AppKit
import CryptoKit
import Foundation
import SwitchShelfDomain

/// Content and two-axis visibility evidence from a real production WindowGroup.
/// Only bootstrap/state/defaults are replaced; native window sizing is retained.
extension AppModel {
    func verifyStagingWindowMatrix() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!)
        let source = LibrarySource(id: "matrix-source", url: root, name: "合成离线来源 · 仅用于窗口内容验收", availability: .offline)
        let games = (1...5).map { index in
            let contents: [LocalContent] = [
                LocalContent(id: "matrix-base-\(index)", titleID: "0100000000000000", kind: .base, rawVersion: 0,
                             fileURL: root.appendingPathComponent("fixture-\(index)-base.nsp"), byteCount: 3, format: .nsp, availability: .offline),
                LocalContent(id: "matrix-update-\(index)", titleID: "0100000000000800", kind: .update, rawVersion: 65536,
                             fileURL: root.appendingPathComponent("fixture-\(index)-update.nsp"), byteCount: 3, format: .nsp, availability: .offline),
                LocalContent(id: "matrix-dlc-\(index)", titleID: "0100000000001001", kind: .dlc, rawVersion: 0,
                             fileURL: root.appendingPathComponent("fixture-\(index)-dlc.nsp"), byteCount: 3, format: .nsp, availability: .offline)
            ]
            return Game(id: "matrix-\(index)", title: "原生窗口合成游戏 \(index) · 很长的标题验证横向压缩", contents: contents, identification: .needsReview)
        }
        let populated = LibrarySnapshot(sources: [source], games: games)
        let plan = games.prefix(2).map { PlanItem(game: $0) }
        try await validateMatrixState("empty", snapshot: LibrarySnapshot(), plan: [], layout: .grid)
        try await validateMatrixState("populated-grid", snapshot: populated, plan: plan, layout: .grid)
        try await validateMatrixState("populated-list", snapshot: populated, plan: plan, layout: .list)
        var uncertain = games[0]
        uncertain.contents[1].rawVersion = nil
        try await validateMatrixState("ambiguous-expanded", snapshot: LibrarySnapshot(sources: [source], games: [uncertain]),
                                      plan: [PlanItem(game: uncertain)], layout: .grid)
        seedUIReview(LibrarySnapshot(), plan: [], page: .all, layout: .grid, inspector: false)
        print("PASS: native content matrix — empty/populated grid/populated list/expanded ambiguous choice, four sizes, both axes and thumbnail/control bounds.")
    }

    private func validateMatrixState(_ name: String, snapshot: LibrarySnapshot, plan: [PlanItem], layout: LibraryLayout) async throws {
        seedUIReview(snapshot, plan: plan, page: .all, layout: layout, inspector: false)
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) else {
            throw NSError(domain: "StagingMatrix", code: 1)
        }
        for (width, height) in [(960.0, 640.0), (1280, 820), (1516, 809), (1276, 1410)] {
            window.setContentSize(NSSize(width: width, height: height))
            try await WindowLayoutEvidence.waitForStableGeometry(window: window, width: width)
            guard let content = window.contentView else { throw NSError(domain: "StagingMatrix", code: 2) }
            let viewport = CGRect(origin: .zero, size: content.bounds.size)
            print("MATRIX GEOMETRY \(name) \(width)x\(height) viewport=\(viewport): \(WindowLayoutEvidence.frames)")
            if CommandLine.arguments.contains("--dump-layout") { WindowLayoutEvidence.dump(content, in: window) }
            var checked = [String: CGRect]()
            func requireFrame(_ key: String, inside parent: CGRect = .null) throws -> CGRect {
                guard let rect = WindowLayoutEvidence.frames[key], !rect.isEmpty,
                      [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) else {
                    throw NSError(domain: "StagingMatrix", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing visible frame: \(key)"])
                }
                let bound = parent.isNull ? viewport : parent
                guard bound.insetBy(dx: -1, dy: -1).contains(rect) else {
                    throw NSError(domain: "StagingMatrix", code: 4, userInfo: [NSLocalizedDescriptionKey:
                        "\(name) \(width)x\(height): \(key) \(rect) exceeds \(bound) (both-axis check)"])
                }
                checked[key] = rect
                return rect
            }
            for key in ["brand", "header", "installButton", "staging", "stagingViewport"] { _ = try requireFrame(key) }
            let sidebar = checked["staging"]!
            guard abs(sidebar.width - 320) < 1 else { throw NSError(domain: "StagingMatrix", code: 5) }
            if let first = snapshot.games.first {
                let library = try requireFrame(layout == .grid ? "gridViewport" : "listViewport")
                guard library.maxX <= sidebar.minX + 1 else { throw NSError(domain: "StagingMatrix", code: 6) }
                let visibleGames = layout == .grid ? Array(snapshot.games.prefix(1)) : Array(snapshot.games.prefix(2))
                for game in visibleGames {
                    let info = try requireFrame("details-\(layout.rawValue)-\(game.id)", inside: library)
                    guard info.width >= 20, info.height >= 20 else { throw NSError(domain: "StagingMatrix", code: 7) }
                    let bodyKey = layout == .grid ? "card-\(game.id)" : "row-\(game.id)"
                    guard let body = WindowLayoutEvidence.frames[bodyKey],
                          body.minX >= library.minX - 1, body.maxX <= library.maxX + 1,
                          body.intersection(library).height >= min(80, body.height) else {
                        throw NSError(domain: "StagingMatrix", code: 8,
                                      userInfo: [NSLocalizedDescriptionKey: "\(name): source row/card clipped horizontally or not meaningfully visible"])
                    }
                    checked[bodyKey] = body
                    if layout == .list {
                        _ = try requireFrame("library-cover-list-\(game.id)", inside: library)
                        _ = try requireFrame("library-bytes-\(game.id)", inside: library)
                    }
                }
                for item in plan {
                    let stageViewport = checked["stagingViewport"]!
                    let title = try requireFrame("staged-title-\(item.gameID)", inside: stageViewport)
                    let remove = try requireFrame("remove-staged-\(item.gameID)", inside: stageViewport)
                    let cover = try requireFrame("staging-cover-\(item.gameID)", inside: stageViewport)
                    let card = WindowLayoutEvidence.frames["staged-card-\(item.gameID)"] ?? .null
                    guard !card.isNull, card.minX >= sidebar.minX, card.maxX <= sidebar.maxX,
                          card.insetBy(dx: -1, dy: -1).contains(title), card.insetBy(dx: -1, dy: -1).contains(remove),
                          card.insetBy(dx: -1, dy: -1).contains(cover) else {
                        throw NSError(domain: "StagingMatrix", code: 9)
                    }
                    if name != "ambiguous-expanded" { _ = try requireFrame("staged-card-\(item.gameID)", inside: stageViewport) }
                }
                if name == "ambiguous-expanded" {
                    guard needsUpdateChoice(plan[0]), !canBeginStagedInstallation else { throw NSError(domain: "StagingMatrix", code: 10) }
                }
                // Explicitly state which game is required to be visible; later cards
                // can correctly remain below the ScrollView's visible viewport.
                print("MATRIX \(name) \(width)x\(height): first game \(first.id), \(plan.count) staged, x/y and button bounds PASS")
            } else {
                guard self.plan.isEmpty else { throw NSError(domain: "StagingMatrix", code: 11) }
                print("MATRIX \(name) \(width)x\(height): empty staging and x/y bounds PASS")
            }
            let saveImage = width == 960 || (name == "populated-grid" && width == 1280)
            try WindowLayoutEvidence.record(window: window, name: "\(name)-\(Int(width))x\(Int(height))",
                                            checkedFrames: checked, saveImage: saveImage,
                                            state: name, stagedCount: self.plan.count, libraryCount: games.count)
        }
    }
}

extension WindowLayoutEvidence {
    static func waitForStableGeometry(window: NSWindow, width: Double) async throws {
        var previous: [String: CGRect] = [:]
        var stable = 0
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            guard let bounds = window.contentView?.bounds,
                  abs(bounds.width - width) <= 1,
                  let side = frames["staging"], let header = frames["header"], let button = frames["installButton"],
                  abs(side.maxX - bounds.maxX) <= 1,
                  abs(header.maxX + 1 - side.minX) <= 1,
                  abs(button.maxY + 16 - bounds.maxY) <= 1 else { continue }
            let keys = ["brand", "header", "installButton", "staging", "stagingViewport"]
            let current = frames.filter { keys.contains($0.key) }
            guard current.count == keys.count,
                  current.values.allSatisfy({ bounds.insetBy(dx: -1, dy: -1).contains($0) }) else { continue }
            stable = current == previous ? stable + 1 : 0
            previous = current
            if stable >= 2 { return }
        }
        throw NSError(domain: "StagingMatrix", code: 12,
                      userInfo: [NSLocalizedDescriptionKey: "Geometry did not settle inside the viewport within 2 seconds: \(frames)"])
    }

    private static var variant: String {
        let appearance = CommandLine.arguments.contains("--dark") ? "dark" : "light"
        return appearance + (CommandLine.arguments.contains("--reduce-motion") ? "-reduced" : "-animated")
    }

    static func record(window: NSWindow, name: String, checkedFrames: [String: CGRect] = [:], saveImage: Bool = true,
                       state: String, stagedCount: Int, libraryCount: Int) throws {
        guard let path = ProcessInfo.processInfo.environment["SWITCHSHELF_NATIVE_EVIDENCE"] else {
            throw NSError(domain: "NativeEvidence", code: 1)
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(variant, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let content = window.contentView else { throw NSError(domain: "NativeEvidence", code: 2) }
        var entry: [String: Any] = [
            "name": name, "state": state, "stagedGames": stagedCount, "libraryGames": libraryCount,
            "captureMethod": "active production WindowGroup contentView NSView.cacheDisplay (in-process)",
            "fixtureOnly": true, "nativeSizingNotOverridden": true,
            "viewport": rectJSON(CGRect(origin: .zero, size: content.bounds.size)),
            "windowFrame": rectJSON(window.frame),
            "checkedFrames": checkedFrames.mapValues(rectJSON),
            "noBootstrapUSBOrInstallation": true
        ]
        if saveImage {
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw NSError(domain: "NativeEvidence", code: 3)
            }
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            // Sheet backing materials are not drawn into cacheDisplay: its text
            // may be black with transparency. Composite the captured pixels over
            // the real window-background color; never invent/repaint controls.
            guard let image = bitmap.cgImage,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(data: nil, width: image.width, height: image.height,
                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw NSError(domain: "NativeEvidence", code: 4)
            }
            var background = CGColor(gray: 1, alpha: 1)
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)?.cgColor ?? background
            }
            let pixelRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            canvas.setFillColor(background)
            canvas.fill(pixelRect)
            canvas.draw(image, in: pixelRect)
            guard let opaqueImage = canvas.makeImage(),
                  let data = NSBitmapImageRep(cgImage: opaqueImage).representation(using: .png, properties: [:]) else {
                throw NSError(domain: "NativeEvidence", code: 5)
            }
            entry["backgroundComposite"] = "captured alpha over NSColor.windowBackgroundColor for the native effective appearance"
            let file = name + ".png"
            try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            entry["image"] = file
            entry["imageSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            entry["pixelWidth"] = bitmap.pixelsWide
            entry["pixelHeight"] = bitmap.pixelsHigh
        }
        try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
    }

    private static func rectJSON(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
