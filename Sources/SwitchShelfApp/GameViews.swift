import AppKit
import ImageIO
import SwiftUI
import SwitchShelfDomain
import SwitchShelfLibrary

/// Decoded, bounded pixels and palette can cross back to MainActor without
/// forcing JPEG decoding or color sampling during the inspector animation.
struct PreparedCover: Sendable {
    let image: CGImage
    let palette: CoverPalette

    static func decode(_ thumbnail: CoverThumbnail) -> PreparedCover? {
        guard !thumbnail.jpegData.isEmpty, thumbnail.jpegData.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(thumbnail.jpegData as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: CoverImageLoader.maxPixel,
                  kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return PreparedCover(image: image, palette: CoverPalette.sample(image))
    }
}

private final class CachedCover: NSObject {
    let image: NSImage
    let thumbnail: CoverThumbnail
    let tint: Color
    var isSquare: Bool { thumbnail.isSquare }

    init(prepared: PreparedCover, thumbnail: CoverThumbnail) {
        image = NSImage(cgImage: prepared.image,
                        size: NSSize(width: prepared.image.width, height: prepared.image.height))
        self.thumbnail = thumbnail
        let palette = prepared.palette
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
        let cost = Int(cover.image.size.width * cover.image.size.height * 4) + cover.thumbnail.jpegData.count
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
                        .scaledToFill()
                        .frame(
                            width: proxy.size.width,
                            height: cover.isSquare && showsTitle ? proxy.size.width : proxy.size.height,
                            alignment: .top
                        )
                        .clipped()
                } else {
                    CoverPlaceholder(title: game.title, seed: game.id)
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
                        if let installationAssessment, installationAssessment.state == .installed || installationAssessment.state == .partial {
                            InstallationMark(state: installationAssessment.state, onCover: true)
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
        .task(id: coverTaskID) { await loadCover() }
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
        // Revalidate local metadata before using a thumbnail. A URL-only memory
        // hit would hide a changed file or a newly substituted symbolic link.
        let store = CoverImageCache.disk
        let thumbnail = await Task.detached(priority: .utility) { () -> CoverThumbnail? in
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
            guard let values = try? url.resourceValues(forKeys: keys) else {
                return store.latestCachedThumbnail(for: url)
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true else { return nil }
            let byteCount = Int64(values.fileSize ?? 0)
            let modifiedAt = values.contentModificationDate
            if let cached = store.cachedThumbnail(for: url, byteCount: byteCount, modifiedAt: modifiedAt) {
                return cached
            }
            guard let created = CoverImageLoader.thumbnail(at: url) else { return nil }
            store.save(created, for: url, byteCount: byteCount, modifiedAt: modifiedAt)
            return created
        }.value
        await apply(thumbnail, cacheKey: url)
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
        await apply(thumbnail, cacheKey: cacheKey)
    }

    private func apply(_ thumbnail: CoverThumbnail?, cacheKey: URL) async {
        guard !Task.isCancelled else { return }
        guard let thumbnail else { cover = nil; return }
        // Local source metadata was revalidated above. Reuse decoded pixels only
        // when the validated thumbnail bytes still match, including offline hits.
        if let cached = CoverImageCache.image(for: cacheKey), cached.thumbnail == thumbnail {
            cover = cached
            return
        }
        let prepared = await Task.detached(priority: .utility) {
            PreparedCover.decode(thumbnail)
        }.value
        guard !Task.isCancelled else { return }
        if let prepared {
            let loaded = CachedCover(prepared: prepared, thumbnail: thumbnail)
            CoverImageCache.insert(loaded, for: cacheKey)
            cover = loaded
        } else { cover = nil }
    }
}

struct InstallationMark: View {
    var state: InstallationState
    var onCover = false

    private var title: String {
        switch state {
        case .installed: "已安装"
        case .partial: "部分安装"
        default: ""
        }
    }

    private var symbol: String {
        state == .partial ? "circle.lefthalf.filled" : "checkmark.circle.fill"
    }

    private var color: Color {
        if onCover {
            return state == .partial
                ? Color(.sRGB, red: 1, green: 0.78, blue: 0.42, opacity: 1)
                : Color(.sRGB, red: 0.35, green: 0.95, blue: 0.72, opacity: 1)
        }
        return state == .partial ? Theme.warning : Theme.installed
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .fixedSize()
    }
}

struct CoverPlaceholder: View {
    var title: String
    var seed: String

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

                Group {
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
    let installationMotion: Namespace.ID
    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var assessment: InstallationAssessment { model.assessment(for: game) }
    private var isOffline: Bool {
        !game.contents.isEmpty && game.contents.allSatisfy { $0.availability == .offline }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                withAnimation(.snappy(duration: 0.36)) { model.handleGridTap(game) }
            } label: {
        VStack(alignment: .leading, spacing: 8) {
            CoverArtwork(game: game, showsTitle: true, installationAssessment: assessment)
                .aspectRatio(3 / 4, contentMode: .fit)
                .modifier(InstallationMotion(id: game.id, namespace: installationMotion, enabled: !isSelected))
                .accessibilityIdentifier("library-cover-grid-\(game.id)")
                .overlay(alignment: .topLeading) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 6) {
                            availabilityBadges
                            Spacer(minLength: 0)
                            identityBadge.padding(.trailing, 28)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            identityBadge
                            availabilityBadges
                        }
                    }
                    .padding(7)
                }
                .overlay {
                    selectionEdge.animation(.smooth(duration: 0.18), value: isSelected)
                }
                .shadow(color: .black.opacity(isHovering ? 0.16 : 0.08), radius: isHovering ? 12 : 6, y: isHovering ? 6 : 3)
                .scaleEffect(isHovering ? 1.012 : 1)
                .animation(.smooth(duration: 0.16), value: isHovering)
                .animation(.smooth(duration: 0.16), value: isFocused)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(game.contentSummary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(formatByteCount(game.byteCount))
                        .monospacedDigit()
                        .fixedSize()
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            GameDetailsButton(model: model, game: game).padding(7)
        }
        .onHover { isHovering = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            withAnimation(.snappy(duration: 0.36)) { model.handleGridTap(game) }
            return .handled
        }
        .onKeyPress(.return) {
            withAnimation(.snappy(duration: 0.36)) { model.handleGridTap(game) }
            return .handled
        }
        .contextMenu { contextActions }
        .accessibilityIdentifier("game-card-\(game.id)")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(game.title)，\(game.contentSummary)，\(formatByteCount(game.byteCount))")
        .accessibilityValue("\(isSelected ? "已选择" : "未选择")，\(assessment.state.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "加入待选区") { model.handleGridTap(game) }
        .accessibilityAction(named: "查看详情") { model.openGameDetails(game) }
    }

    /// Selected light stays in a thin rim on the cover. Clipped so it cannot paint the caption below.
    private var selectionEdge: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return ZStack {
            if isSelected {
                shape
                    .stroke(edgeGradient, lineWidth: 8)
                    .blur(radius: 3.5)
                    .mask { shape.stroke(Color.white, lineWidth: 11) }
                shape.strokeBorder(edgeGradient, lineWidth: 1)
            } else {
                shape.strokeBorder(
                    (isHovering || isFocused) ? Theme.accent.opacity(0.32) : Theme.hairline,
                    lineWidth: 1
                )
            }
        }
        .clipShape(shape)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var edgeGradient: LinearGradient {
        let dark = colorScheme == .dark
        return LinearGradient(
            stops: [
                .init(color: Color.white.opacity(dark ? 0.28 : 0.55), location: 0),
                .init(color: Color.white.opacity(dark ? 0.05 : 0.10), location: 0.28),
                .init(color: Theme.accent.opacity(dark ? 0.22 : 0.14), location: 0.52),
                .init(color: Theme.accent.opacity(dark ? 0.92 : 0.78), location: 0.84),
                .init(color: Theme.violet.opacity(dark ? 0.88 : 0.70), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var availabilityBadges: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isOffline {
                BadgePill(text: "离线", systemImage: "wifi.slash", tone: .neutral, solid: true)
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var identityBadge: some View {
        if game.identification.isPending {
            BadgePill(text: game.identification.label, systemImage: "questionmark", tone: .warning, solid: true)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var contextActions: some View {
        Button("在访达中显示") { model.revealGame(game) }
        Button("加入待选区") { model.addToQueue(game) }
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
    let installationMotion: Namespace.ID

    private var assessment: InstallationAssessment { model.assessment(for: game) }
    private var isOffline: Bool {
        !game.contents.isEmpty && game.contents.allSatisfy { $0.availability == .offline }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button {
                withAnimation(.snappy(duration: 0.36)) { model.handleGridTap(game) }
            } label: {
                HStack(spacing: 12) {
                    CoverArtwork(game: game, cornerRadius: 6)
                        .frame(width: 44, height: 44)
                        .modifier(InstallationMotion(id: game.id, namespace: installationMotion, enabled: !isSelected))
                        .accessibilityIdentifier("library-cover-list-\(game.id)")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(game.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if assessment.state == .installed || assessment.state == .partial {
                                InstallationMark(state: assessment.state).help(assessment.explanation)
                            }
                        }
                        HStack(spacing: 4) {
                            Text(game.contentSummary).lineLimit(1).layoutPriority(1)
                            Spacer(minLength: 4)
                            Text(formatByteCount(game.byteCount))
                                .monospacedDigit().fixedSize()
                                .frame(width: 74, alignment: .trailing)
                                .accessibilityIdentifier("library-bytes-\(game.id)")
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            if isOffline {
                                BadgePill(text: "离线", systemImage: "wifi.slash", tone: .neutral)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            if game.identification.isPending {
                                BadgePill(text: game.identification.label, systemImage: "questionmark", tone: .warning)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Text("\(game.contents.count) 个文件").font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                            if let source = model.sources(for: game).first {
                                Text(source.name).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, 34)
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Theme.accent.opacity(0.14) : Color.clear)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            GameDetailsButton(model: model, game: game, placement: .list).padding(.trailing, 5)
        }
        .accessibilityIdentifier("game-row-\(game.id)")
        .focusable()
        .onKeyPress(.return) {
            withAnimation(.snappy(duration: 0.36)) { model.handleGridTap(game) }
            return .handled
        }
        .contextMenu {
            Button("在访达中显示") { model.revealGame(game) }
            Button("加入待选区") { model.addToQueue(game) }
            if model.isInPlan(game.id) { Button("查看安装队列") { model.showQueue() } }
            Divider()
            if let titleID = game.contents.compactMap(\.titleID).first {
                Button("复制 Title ID") { model.copyTitleID(titleID) }
            }
        }
        .accessibilityElement(children: .contain)
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
