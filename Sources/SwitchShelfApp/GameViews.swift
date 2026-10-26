import AppKit
import SwiftUI
import SwitchShelfDomain
import SwitchShelfLibrary

private final class CachedCover: NSObject {
    let image: NSImage
    let isSquare: Bool
    let tint: Color

    init(image: NSImage, isSquare: Bool) {
        self.image = image
        self.isSquare = isSquare
        let palette = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map(CoverPalette.sample) ?? .fallback
        tint = Color(.sRGB, red: palette.red, green: palette.green, blue: palette.blue, opacity: 1)
    }
}

@MainActor
private enum CoverImageCache {
    private static let images: NSCache<NSURL, CachedCover> = {
        let cache = NSCache<NSURL, CachedCover>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    static let disk = CoverThumbnailStore(
        directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("SwitchShelf/CoverThumbnails", isDirectory: true)
    )

    static func image(for url: URL) -> CachedCover? {
        images.object(forKey: url as NSURL)
    }

    static func insert(_ cover: CachedCover, for url: URL) {
        let cost = Int(cover.image.size.width * cover.image.size.height * 4)
        images.setObject(cover, forKey: url as NSURL, cost: cost)
    }
}

struct CoverArtwork: View {
    var game: Game
    var cornerRadius: CGFloat = 12
    var showsTitle = false
    var installationAssessment: InstallationAssessment?
    @State private var cover: CachedCover?

    private var tint: Color {
        cover?.tint ?? Color(.sRGB, red: 0.10, green: 0.13, blue: 0.18, opacity: 1)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                if let cover {
                    tint
                    Image(nsImage: cover.image)
                        .resizable()
                        .aspectRatio(contentMode: cover.isSquare && !showsTitle ? .fit : .fill)
                        .frame(
                            width: proxy.size.width,
                            height: cover.isSquare && showsTitle ? proxy.size.width : proxy.size.height,
                            alignment: showsTitle ? .top : .center
                        )
                        .clipped()
                } else {
                    CoverPlaceholder(title: game.title, seed: game.id, showsTitle: !showsTitle)
                }

                if showsTitle {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0.30),
                        .init(color: tint.opacity(0.10), location: 0.46),
                        .init(color: tint.opacity(0.76), location: 0.64),
                        .init(color: tint, location: 0.75),
                        .init(color: tint, location: 1)
                    ], startPoint: .top, endPoint: .bottom)

                    VStack(alignment: .leading, spacing: 5) {
                        if cover == nil {
                            Text("暂无封面")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        if let installationAssessment, installationAssessment.state == .installed {
                            InstalledGameLabel(onCover: true)
                                .help(installationAssessment.explanation)
                        }
                        Text(game.title)
                            .font(.system(size: max(12, min(20, proxy.size.width * 0.085)), weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    }
                    .padding(max(10, proxy.size.width * 0.065))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        }
        .task(id: coverTaskID) {
            await loadCover()
        }
        .accessibilityLabel(cover == nil ? "缺少封面：\(game.title)" : "\(game.title) 封面")
    }

    private var coverTaskID: String {
        if let local = game.coverURL?.absoluteString { return "local:\(local)" }
        return "nlib:\(NlibCoverClient.titleID(for: game) ?? "")"
    }

    private func loadCover() async {
        cover = nil
        if let url = game.coverURL, url.isFileURL {
            await loadLocalCover(at: url)
        } else if let titleID = NlibCoverClient.titleID(for: game), let remote = NlibCoverClient.iconURL(for: titleID) {
            await loadRemoteCover(titleID: titleID, cacheKey: remote)
        } else {
            cover = nil
        }
    }

    private func loadLocalCover(at url: URL) async {
        if let cached = CoverImageCache.image(for: url) {
            cover = cached
            return
        }
        let store = CoverImageCache.disk
        let thumbnail = await Task.detached(priority: .utility) { () -> CoverThumbnail? in
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isSymbolicLink != true, values?.isRegularFile != false else { return nil }
            let byteCount = Int64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate
            if let cached = store.cachedThumbnail(for: url, byteCount: byteCount, modifiedAt: modifiedAt) {
                return cached
            }
            guard let created = CoverImageLoader.thumbnail(at: url) else { return nil }
            store.save(created, for: url, byteCount: byteCount, modifiedAt: modifiedAt)
            return created
        }.value
        apply(thumbnail, cacheKey: url)
    }

    private func loadRemoteCover(titleID: String, cacheKey: URL) async {
        if let cached = CoverImageCache.image(for: cacheKey) {
            cover = cached
            return
        }
        cover = nil
        let store = CoverImageCache.disk
        let thumbnail = await Task.detached(priority: .utility) { () -> CoverThumbnail? in
            if let cached = store.cachedThumbnail(for: cacheKey, byteCount: 0, modifiedAt: nil) {
                return cached
            }
            guard let created = await NlibCoverFetcher.shared.thumbnail(for: titleID) else { return nil }
            store.save(created, for: cacheKey, byteCount: 0, modifiedAt: nil)
            return created
        }.value
        apply(thumbnail, cacheKey: cacheKey)
    }

    private func apply(_ thumbnail: CoverThumbnail?, cacheKey: URL) {
        guard !Task.isCancelled else { return }
        if let thumbnail, let loaded = NSImage(data: thumbnail.jpegData) {
            let loadedCover = CachedCover(image: loaded, isSquare: thumbnail.isSquare)
            CoverImageCache.insert(loadedCover, for: cacheKey)
            cover = loadedCover
        } else {
            cover = nil
        }
    }
}

struct InstalledGameLabel: View {
    var onCover = false

    var body: some View {
        Label("已安装", systemImage: "checkmark.circle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(onCover
                ? Color(.sRGB, red: 0.35, green: 0.95, blue: 0.72, opacity: 1)
                : Theme.installed)
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}

struct CoverPlaceholder: View {
    var title: String
    var seed: String
    var showsTitle = true
    var showsMissingCaption = true
    var showsMonogram = true

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let hue = stableHue(seed + title)
            let deepHue = (hue + 0.07).truncatingRemainder(dividingBy: 1)

            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.52, brightness: 0.78),
                        Color(hue: deepHue, saturation: 0.74, brightness: 0.42)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.26), .clear],
                    center: .topLeading,
                    startRadius: 2,
                    endRadius: width * 1.1
                )

                if showsMonogram {
                    Text(monogram)
                        .font(.system(size: width * 0.34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .offset(y: -width * 0.06)
                }

                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.10), Color.black.opacity(0.52)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: max(2, width * 0.016)) {
                    if showsMissingCaption, width > 86 {
                        Text("本地封面未提供")
                            .font(.system(size: max(7, min(9, width * 0.055)), weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
                    Text(title)
                        .font(.system(size: max(7, min(17, width * 0.095)), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .padding(max(6, width * 0.065))
                .opacity(showsTitle ? 1 : 0)
            }
        }
        .accessibilityHidden(true)
    }

    private var monogram: String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(1)).uppercased()
    }
}

struct GameCard: View {
    @Bindable var model: AppModel
    var game: Game
    var isSelected: Bool
    @State private var isHovering = false

    private var assessment: InstallationAssessment { model.assessment(for: game) }
    private var isOffline: Bool {
        !game.contents.isEmpty && game.contents.allSatisfy { $0.availability == .offline }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverArtwork(game: game, showsTitle: true, installationAssessment: assessment)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        if isOffline {
                            BadgePill(text: "离线", systemImage: "wifi.slash", tone: .neutral, solid: true)
                        }
                    }
                    .padding(7)
                }
                .overlay(alignment: .topTrailing) {
                    if game.identification.isPending {
                        BadgePill(
                            text: game.identification.label,
                            systemImage: "questionmark",
                            tone: .warning,
                            solid: true
                        )
                        .padding(7)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Theme.accent : (isHovering ? Theme.accent.opacity(0.45) : Theme.hairline),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }
                .shadow(color: .black.opacity(isHovering ? 0.16 : 0.08), radius: isHovering ? 12 : 6, y: isHovering ? 6 : 3)
                .scaleEffect(isHovering ? 1.012 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(game.contentSummary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(formatByteCount(game.byteCount))
                        .monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.handleGridTap(game) }
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.16)) { isHovering = hovering }
        }
        .focusable()
        .onKeyPress(.space) {
            model.handleGridTap(game)
            return .handled
        }
        .onKeyPress(.return) {
            model.handleGridTap(game)
            return .handled
        }
        .contextMenu { contextActions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title)，\(game.contentSummary)，\(formatByteCount(game.byteCount))")
        .accessibilityValue("\(isSelected ? "已选择" : "未选择")，\(assessment.state.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "选择或取消选择") { model.handleGridTap(game) }
        .accessibilityAction(named: "加入安装队列") { model.addToQueue(game) }
    }

    @ViewBuilder
    private var contextActions: some View {
        Button("在访达中显示") { model.revealGame(game) }
        Button("加入安装队列") { model.addToQueue(game) }
        if model.isInPlan(game.id) {
            Button("查看安装队列") { model.showQueue() }
        }
        Divider()
        if let titleID = game.contents.compactMap(\.titleID).first {
            Button("复制 Title ID") { model.copyTitleID(titleID) }
        }
        if let url = game.revealURL {
            Button("复制文件路径") { model.copyPath(url) }
        }
    }
}

struct GameListRow: View {
    @Bindable var model: AppModel
    var game: Game
    var isSelected: Bool

    private var assessment: InstallationAssessment { model.assessment(for: game) }
    private var isOffline: Bool {
        !game.contents.isEmpty && game.contents.allSatisfy { $0.availability == .offline }
    }

    var body: some View {
        HStack(spacing: 12) {
            CoverArtwork(game: game, cornerRadius: 6)
                .frame(width: 40, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(game.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if assessment.state == .installed {
                        InstalledGameLabel()
                            .help(assessment.explanation)
                    }
                }
                HStack(spacing: 6) {
                    Text(game.contentSummary)
                    Text("·")
                    Text(game.contents.count == 1 ? "1 个文件" : "\(game.contents.count) 个文件")
                    if let source = model.sources(for: game).first {
                        Text("·")
                        Text(source.name).lineLimit(1)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            if isOffline {
                BadgePill(text: "离线", systemImage: "wifi.slash", tone: .neutral)
            }
            if game.identification.isPending {
                BadgePill(text: game.identification.label, systemImage: "questionmark", tone: .warning)
            }
            Text(formatByteCount(game.byteCount))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.14) : Color.clear)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("在访达中显示") { model.revealGame(game) }
            Button("加入安装队列") { model.addToQueue(game) }
            if model.isInPlan(game.id) { Button("查看安装队列") { model.showQueue() } }
            Divider()
            if let titleID = game.contents.compactMap(\.titleID).first {
                Button("复制 Title ID") { model.copyTitleID(titleID) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title)，\(game.contentSummary)，\(formatByteCount(game.byteCount))")
        .accessibilityValue(assessment.state.label)
    }
}

struct ContentKindIcon: View {
    var kind: ContentKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: 26, height: 26)
            .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}
