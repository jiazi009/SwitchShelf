import AppKit
import SwiftUI
import SwitchShelfDomain
import SwitchShelfLibrary

private final class CachedCover: NSObject {
    let image: NSImage
    let isSquare: Bool
    init(image: NSImage, isSquare: Bool) {
        self.image = image
        self.isSquare = isSquare
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

    static func insert(_ image: NSImage, isSquare: Bool, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        images.setObject(CachedCover(image: image, isSquare: isSquare), forKey: url as NSURL, cost: cost)
    }
}

struct CoverArtwork: View {
    var game: Game
    var cornerRadius: CGFloat = 12
    @State private var image: NSImage?
    @State private var isSquare = false

    var body: some View {
        ZStack {
            if let image, !isSquare {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CoverPlaceholder(
                    title: game.title,
                    seed: game.id,
                    showsMissingCaption: image == nil,
                    showsMonogram: image == nil
                )
                if let image, isSquare {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 36)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
        }
        .task(id: coverTaskID) {
            await loadCover()
        }
        .accessibilityLabel(image == nil ? "缺少封面：\(game.title)" : "\(game.title) 封面")
    }

    private var coverTaskID: String {
        if let local = game.coverURL?.absoluteString { return "local:\(local)" }
        return "nlib:\(NlibCoverClient.titleID(for: game) ?? "")"
    }

    private func loadCover() async {
        if let url = game.coverURL, url.isFileURL {
            await loadLocalCover(at: url)
        } else if let titleID = NlibCoverClient.titleID(for: game), let remote = NlibCoverClient.iconURL(for: titleID) {
            await loadRemoteCover(titleID: titleID, cacheKey: remote)
        } else {
            image = nil
            isSquare = false
        }
    }

    private func loadLocalCover(at url: URL) async {
        if let cached = CoverImageCache.image(for: url) {
            image = cached.image
            isSquare = cached.isSquare
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
            image = cached.image
            isSquare = cached.isSquare
            return
        }
        image = nil
        isSquare = false
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
            CoverImageCache.insert(loaded, isSquare: thumbnail.isSquare, for: cacheKey)
            image = loaded
            isSquare = thumbnail.isSquare
        } else {
            image = nil
            isSquare = false
        }
    }
}

struct CoverPlaceholder: View {
    var title: String
    var seed: String
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
            CoverArtwork(game: game)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        if assessment.state == .installed {
                            BadgePill(text: "已安装", systemImage: "checkmark.seal.fill", tone: .success, solid: true)
                        }
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
                Text(game.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
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
        .accessibilityValue(isSelected ? "已选择" : "未选择")
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
                Text(game.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
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
            if assessment.state == .installed {
                BadgePill(text: "已安装", systemImage: "checkmark.seal.fill", tone: .success)
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
