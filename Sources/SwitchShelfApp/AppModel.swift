import AppKit
import CoreGraphics
import Foundation
import Observation
import SwitchShelfDevice
import SwitchShelfDomain
import SwitchShelfLibrary
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {
    // MARK: Library data
    private(set) var snapshot = LibrarySnapshot()
    private(set) var plan: [PlanItem] = []
    private(set) var firstSeen: [String: Date] = [:]
    private(set) var inventory: InstalledInventory?
    private(set) var inventorySessionSignature: String?
    private(set) var deviceDiscovery: DeviceDiscovery?
    private(set) var cacheLoaded = false
    private(set) var isBootstrapped = false
    private(set) var isScanning = false
    private(set) var scanPhase: String?
    private(set) var isDiscovering = false
    private(set) var isReadingInventory = false

    // MARK: UI state
    private(set) var selection: SidebarItem? = .all
    var selectedGameIDs: Set<String> = []
    private(set) var activeGameID: String?
    var searchText = ""
    var contentFilter: ContentFilter = .all
    var installFilter: InstallFilter = .all
    var sortOrder: SortOrder = .recent {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "SwitchShelf.sortOrder") }
    }
    var layout: LibraryLayout = .grid {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "SwitchShelf.layout") }
    }
    var coverSize: Double = 172 {
        didSet {
            let clamped = min(max(coverSize, 120), 240)
            UserDefaults.standard.set(clamped, forKey: "SwitchShelf.coverSize")
        }
    }
    var inspectorPresented = true
    var searchFocusToken = 0
    var notice: AppNotice?
    var sourcePendingRemoval: LibrarySource?

    // MARK: Services
    @ObservationIgnored private let scanner: any LibraryScanning = LibraryScanner()
    @ObservationIgnored private let deviceService = DeviceService()
    @ObservationIgnored private let inventoryReader = BoundedInventoryReader()
    @ObservationIgnored private var repository: (any LibraryPersisting)?
    @ObservationIgnored private let appDirectory: URL
    @ObservationIgnored private let planStore: LocalPlanStore
    @ObservationIgnored private var scopedURLs: [String: URL] = [:]
    @ObservationIgnored private var selectionAnchor: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var planSaveTask: Task<Void, Never>?
    @ObservationIgnored private var firstSeenSaveTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapStarted = false
    @ObservationIgnored private var cacheWriteAllowed = false
    @ObservationIgnored private var inspectorAutoHidden = false
    @ObservationIgnored private var lastLayoutWidth: CGFloat = 0

    init() {
        let defaults = UserDefaults.standard
        let directory = Self.applicationSupportDirectory()
        self.appDirectory = directory
        self.planStore = LocalPlanStore(directory: directory)
        self.layout = LibraryLayout(rawValue: defaults.string(forKey: "SwitchShelf.layout") ?? "") ?? .grid
        self.sortOrder = SortOrder(rawValue: defaults.string(forKey: "SwitchShelf.sortOrder") ?? "") ?? .recent
        let storedCover = defaults.double(forKey: "SwitchShelf.coverSize")
        self.coverSize = storedCover >= 120 ? storedCover : 172
    }

    // MARK: - Derived library views

    var games: [Game] { snapshot.games }
    var sources: [LibrarySource] { snapshot.sources }
    var sourceCount: Int { snapshot.sources.count }
    var onlineSourceCount: Int { snapshot.sources.filter { $0.availability == .online }.count }
    var offlineSources: [LibrarySource] { snapshot.sources.filter { $0.availability == .offline } }
    var lastScanDate: Date? { snapshot.scannedAt }
    var scanIssues: [String] { snapshot.issues }

    var isLibraryPage: Bool { (selection ?? .all).isLibraryPage }

    var pageTitle: String {
        switch selection ?? .all {
        case .all: "全部游戏"
        case .recent: "最近添加"
        case .unidentified: "待识别"
        case .queue: "安装队列"
        case .device: "我的 Switch"
        case .maintenance: "维护"
        case .source(let id): snapshot.sources.first { $0.id == id }?.name ?? "游戏来源"
        }
    }

    var pageSubtitle: String {
        switch selection ?? .all {
        case .all:
            return "\(games.count) 款游戏 · \(sources.count) 个来源"
        case .recent:
            return "\(recentGameIDs.count) 款游戏 · 最近 30 天首次在本机发现"
        case .unidentified:
            return "\(unidentifiedCount) 款游戏 · 身份证据不足"
        case .source(let id):
            guard let source = snapshot.sources.first(where: { $0.id == id }) else { return "" }
            return "\(sourceGameCount(id)) 款游戏 · 来源\(source.availability.label)"
        case .queue:
            return "\(plan.count) 项计划 · \(formatByteCount(planTotalBytes)) · 仅保存在本机"
        case .device:
            return deviceSubtitle
        case .maintenance:
            return "本地缓存、扫描与来源诊断"
        }
    }

    var recentGameIDs: Set<String> {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) else { return [] }
        let ids = Set(firstSeen.filter { $0.value >= cutoff }.keys)
        return ids.intersection(Set(games.map(\.id)))
    }

    var unidentifiedCount: Int {
        games.filter { $0.identification.isPending }.count
    }

    var planTotalBytes: Int64 { plan.reduce(0) { $0 + $1.byteCount } }

    var selectedGames: [Game] {
        games.filter { selectedGameIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var activeGame: Game? {
        if selectedGameIDs.count == 1 {
            return games.first { selectedGameIDs.contains($0.id) }
        }
        if let activeGameID, selectedGameIDs.contains(activeGameID) {
            return games.first { $0.id == activeGameID }
        }
        return nil
    }

    var isMultiSelection: Bool { selectedGameIDs.count > 1 }

    var filteredGames: [Game] {
        var result: [Game]
        switch selection ?? .all {
        case .all:
            result = games
        case .recent:
            result = games.filter { recentGameIDs.contains($0.id) }
        case .unidentified:
            result = games.filter { $0.identification.isPending }
        case .source(let id):
            guard let source = snapshot.sources.first(where: { $0.id == id }) else {
                result = []
                break
            }
            result = games.filter { gameBelongs($0, to: source) }
        case .queue, .device, .maintenance:
            result = []
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        if !query.isEmpty {
            result = result.filter { $0.searchHaystack.localizedStandardContains(query) }
        }
        if contentFilter != .all {
            result = result.filter { contentFilter.matches($0) }
        }
        if installFilter != .all {
            result = result.filter { game in
                let state = assessment(for: game).state
                return installFilter == .installed ? state == .installed : state != .installed
            }
        }

        switch sortOrder {
        case .recent:
            result.sort {
                let left = firstSeen[$0.id] ?? .distantPast
                let right = firstSeen[$1.id] ?? .distantPast
                if left == right { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return left > right
            }
        case .title:
            result.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .size:
            result.sort {
                if $0.byteCount == $1.byteCount { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return $0.byteCount > $1.byteCount
            }
        case .contentCount:
            result.sort {
                if $0.contents.count == $1.contents.count { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return $0.contents.count > $1.contents.count
            }
        }
        return result
    }

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || contentFilter != .all
            || installFilter != .all
    }

    var deviceSubtitle: String {
        guard let deviceDiscovery else { return "尚未检测 USB 设备" }
        return deviceDiscovery.message
    }

    var installedGameCount: Int {
        guard inventory != nil else { return 0 }
        return games.filter { assessment(for: $0).state == .installed }.count
    }

    var totalContentCount: Int { games.reduce(0) { $0 + $1.contents.count } }

    var cacheURL: URL { appDirectory.appendingPathComponent("library.sqlite") }
    var appDataPath: String { appDirectory.path }

    // MARK: - Counts for sidebar

    func count(for item: SidebarItem) -> Int? {
        switch item {
        case .all: games.count
        case .recent: recentGameIDs.count
        case .unidentified: unidentifiedCount
        case .queue: plan.count
        case .device, .maintenance: nil
        case .source(let id): sourceGameCount(id)
        }
    }

    func sourceGameCount(_ id: String) -> Int {
        guard let source = snapshot.sources.first(where: { $0.id == id }) else { return 0 }
        return games.filter { gameBelongs($0, to: source) }.count
    }

    func source(withID id: String) -> LibrarySource? {
        snapshot.sources.first { $0.id == id }
    }

    func sources(for game: Game) -> [LibrarySource] {
        snapshot.sources.filter { gameBelongs(game, to: $0) }
    }

    // MARK: - Selection

    func select(_ item: SidebarItem) {
        guard selection != item else { return }
        selection = item
        selectedGameIDs.removeAll()
        activeGameID = nil
        selectionAnchor = nil
    }

    func showAllGames() { select(.all) }
    func showQueue() { select(.queue) }
    func showDevice() { select(.device) }
    func showMaintenance() { select(.maintenance) }

    func focusSearch() {
        if !isLibraryPage { select(.all) }
        searchFocusToken += 1
    }

    func clearFilters() {
        searchText = ""
        contentFilter = .all
        installFilter = .all
    }

    func toggleInspector() {
        inspectorPresented.toggle()
        inspectorAutoHidden = false
    }

    func adaptInspector(to width: CGFloat) {
        defer { lastLayoutWidth = width }
        if lastLayoutWidth == 0 {
            if width < 1120 {
                inspectorAutoHidden = true
                inspectorPresented = false
            }
            return
        }
        if width < 1120, lastLayoutWidth >= 1120 {
            inspectorAutoHidden = true
            inspectorPresented = false
        } else if width >= 1240, lastLayoutWidth < 1240, inspectorAutoHidden {
            inspectorAutoHidden = false
            inspectorPresented = true
        }
    }

    func handleGridTap(_ game: Game) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let ordered = filteredGames.map(\.id)

        if flags.contains(.shift), let anchor = selectionAnchor,
           let anchorIndex = ordered.firstIndex(of: anchor),
           let index = ordered.firstIndex(of: game.id) {
            let range = anchorIndex <= index ? anchorIndex...index : index...anchorIndex
            let ids = Set(ordered[range])
            selectedGameIDs = flags.contains(.command) ? selectedGameIDs.union(ids) : ids
        } else if flags.contains(.command) {
            if selectedGameIDs.contains(game.id) {
                selectedGameIDs.remove(game.id)
            } else {
                selectedGameIDs.insert(game.id)
            }
            selectionAnchor = game.id
        } else {
            selectedGameIDs = [game.id]
            selectionAnchor = game.id
        }
        activeGameID = game.id
        inspectorPresented = true
        inspectorAutoHidden = false
    }

    func selectAllVisible() {
        let ids = filteredGames.map(\.id)
        guard !ids.isEmpty else { return }
        selectedGameIDs = Set(ids)
        activeGameID = ids.first
        selectionAnchor = ids.first
    }

    func clearSelection() {
        selectedGameIDs.removeAll()
        activeGameID = nil
        selectionAnchor = nil
    }

    func syncActiveFromSelection() {
        if selectedGameIDs.count == 1 {
            activeGameID = selectedGameIDs.first
        } else if let activeGameID, !selectedGameIDs.contains(activeGameID) {
            self.activeGameID = selectedGameIDs.first
        } else if selectedGameIDs.isEmpty {
            activeGameID = nil
        }
    }

    // MARK: - Installation assessment

    func assessment(for game: Game) -> InstallationAssessment {
        InstallationAssessor.assess(
            game,
            inventory: inventory,
            isCurrentSession: inventoryIsCurrentSession
        )
    }

    func assessment(for content: LocalContent) -> InstallationAssessment {
        guard InstallationAssessor.normalizedID(content.titleID) != nil else {
            return InstallationAssessment(state: .unknown, explanation: "本地文件名未提供可核对的 Title ID；不推断单项状态。")
        }
        // LocalContent has no independently verified package identity. Even a
        // positive device Title ID match cannot confirm this filename candidate.
        return InstallationAssessment(
            state: .unknown,
            explanation: "本地文件名中的 Title ID 仅为候选，未核对包身份；不推断单项安装状态。",
            observedAt: inventoryIsCurrentSession ? inventory?.observedAt : nil
        )
    }

    // MARK: - Bootstrap & cache

    func bootstrap() async {
        guard !bootstrapStarted else { return }
        bootstrapStarted = true

        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        } catch {
            notice = AppNotice(
                level: .warning,
                title: "无法创建应用数据目录",
                message: "缓存与安装计划可能无法保存：\(error.localizedDescription)",
                action: .openAppSupport,
                actionLabel: "打开目录"
            )
        }

        do {
            let location = cacheURL
            let legacySnapshot = try await Task.detached(priority: .utility) {
                try LibraryCacheMigration.moveLegacyJSONAside(at: location)
            }.value
            let opened = try LibraryRepository(databaseURL: location)
            if let legacySnapshot {
                try await opened.save(legacySnapshot)
            }
            repository = opened
        } catch {
            notice = AppNotice(
                level: .error,
                title: "无法打开本地缓存",
                message: "游戏库仍可扫描，但结果不会持久保存；旧缓存文件未被删除：\(error.localizedDescription)",
                action: .openAppSupport,
                actionLabel: "查看数据目录"
            )
        }

        if let repository {
            do {
                snapshot = try await repository.load()
                cacheLoaded = true
                cacheWriteAllowed = true
            } catch {
                notice = AppNotice(
                    level: .error,
                    title: "无法读取本地缓存",
                    message: "已保留内存中的空游戏库，未覆盖磁盘缓存。\(error.localizedDescription)",
                    action: .reloadCache,
                    actionLabel: "重试"
                )
            }
        }

        ensureInitialSource()
        restoreBookmarks()

        let loadedPlan = await planStore.loadPlan()
        plan = loadedPlan.items
        if let planError = loadedPlan.error {
            notice = AppNotice(
                level: .warning,
                title: "安装计划读取失败",
                message: "已使用空计划，磁盘上的原文件尚未被覆盖。\(planError)"
            )
        }
        firstSeen = await planStore.loadFirstSeen()
        noteFirstSeen(for: snapshot.games, persist: true)

        await refreshSourceAvailability()
        await persistSnapshot()
        isBootstrapped = true

        let refreshOnLaunch = UserDefaults.standard.bool(forKey: AppSettings.refreshOnLaunch)
        if snapshot.games.isEmpty || refreshOnLaunch {
            scanAll()
        }
    }

    func reloadCache() async {
        guard let repository else { return }
        do {
            snapshot = try await repository.load()
            ensureInitialSource()
            restoreBookmarks()
            cacheLoaded = true
            cacheWriteAllowed = true
            noteFirstSeen(for: snapshot.games, persist: true)
            reconcileSelection()
            notice = AppNotice(level: .info, title: "缓存已重新载入", message: "已从本地数据库读取 \(snapshot.games.count) 款游戏。")
        } catch {
            notice = AppNotice(
                level: .error,
                title: "缓存读取仍失败",
                message: error.localizedDescription,
                action: .openAppSupport,
                actionLabel: "查看数据目录"
            )
        }
    }

    private func persistSnapshot() async {
        guard cacheWriteAllowed, let repository else { return }
        let value = snapshot
        do {
            try await repository.save(value)
        } catch {
            notice = AppNotice(
                level: .warning,
                title: "缓存写入失败",
                message: "当前结果仍保留在界面中，但可能无法在下次启动时恢复：\(error.localizedDescription)",
                action: .openAppSupport,
                actionLabel: "查看数据目录"
            )
        }
    }

    private func ensureInitialSource() {
        let url = Self.initialSourceURL
        let path = normalizedPath(url)
        if let index = snapshot.sources.firstIndex(where: { normalizedPath($0.url) == path }) {
            if snapshot.sources[index].availability == .unknown {
                snapshot.sources[index].availability = FileManager.default.fileExists(atPath: path) ? .online : .offline
            }
            return
        }
        guard !UserDefaults.standard.bool(forKey: AppSettings.initialSourceRemoved) else { return }
        snapshot.sources.append(
            LibrarySource(
                id: "source-nas-switch-games",
                url: url,
                name: "switch 游戏包",
                availability: FileManager.default.fileExists(atPath: path) ? .online : .offline
            )
        )
    }

    private func restoreBookmarks() {
        for index in snapshot.sources.indices {
            guard let bookmark = snapshot.sources[index].bookmark else { continue }
            var stale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            if resolved.startAccessingSecurityScopedResource() {
                scopedURLs[snapshot.sources[index].id] = resolved
            }
            snapshot.sources[index].url = resolved
            if stale, let refreshed = try? resolved.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                snapshot.sources[index].bookmark = refreshed
            }
        }
    }

    func refreshSourceAvailability() async {
        let entries = snapshot.sources.map { ($0.id, normalizedPath($0.url)) }
        guard !entries.isEmpty else { return }
        let exists = await Task.detached(priority: .utility) { () -> [String: Bool] in
            var result: [String: Bool] = [:]
            for (id, path) in entries {
                result[id] = FileManager.default.fileExists(atPath: path)
            }
            return result
        }.value
        for index in snapshot.sources.indices {
            if let present = exists[snapshot.sources[index].id] {
                snapshot.sources[index].availability = present ? .online : .offline
            }
        }
    }

    func refreshAvailability() {
        Task {
            await refreshSourceAvailability()
            await persistSnapshot()
        }
    }

    // MARK: - Sources

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "添加来源"
        panel.message = "选择包含 NSP、XCI、NSZ 或 XCZ 的文件夹。SwitchShelf 只读取文件列表，不会移动、修改或删除文件。"
        if FileManager.default.fileExists(atPath: "/Volumes") {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        }
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            for url in urls {
                await addSource(url)
            }
        }
    }

    private func addSource(_ url: URL) async {
        let standardized = url.standardizedFileURL
        let path = normalizedPath(standardized)
        if path == normalizedPath(Self.initialSourceURL) {
            UserDefaults.standard.set(false, forKey: AppSettings.initialSourceRemoved)
        }
        if let existing = snapshot.sources.first(where: { normalizedPath($0.url) == path }) {
            select(.source(existing.id))
            scanSource(existing.id)
            return
        }

        let didAccess = standardized.startAccessingSecurityScopedResource()
        let new = LibrarySource(
            id: UUID().uuidString,
            url: standardized,
            name: standardized.lastPathComponent.isEmpty ? "游戏文件夹" : standardized.lastPathComponent,
            availability: .online
        )
        if didAccess { scopedURLs[new.id] = standardized }
        snapshot.sources.append(new)
        let created = snapshot.sources[snapshot.sources.count - 1]

        var bookmarkError: String?
        do {
            let bookmark = try standardized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            if let index = snapshot.sources.firstIndex(where: { $0.id == created.id }) {
                snapshot.sources[index].bookmark = bookmark
            }
        } catch {
            bookmarkError = error.localizedDescription
        }

        await persistSnapshot()
        select(.source(created.id))

        if let bookmarkError {
            notice = AppNotice(
                level: .info,
                title: "来源已添加",
                message: "但无法保存长期访问书签，重新启动后若无法访问，需要再次添加该文件夹。\(bookmarkError)"
            )
        }

        scanSource(created.id)
    }

    func removeSource(_ source: LibrarySource) {
        snapshot.sources.removeAll { $0.id == source.id }
        snapshot.issues.removeAll { $0.hasPrefix("[\(source.name)] ") }
        if normalizedPath(source.url) == normalizedPath(Self.initialSourceURL) {
            UserDefaults.standard.set(true, forKey: AppSettings.initialSourceRemoved)
        }
        let remaining = snapshot.sources
        for index in snapshot.games.indices {
            snapshot.games[index].contents.removeAll { content in
                !remaining.contains { isUnder(content.fileURL, source: $0) }
            }
        }
        snapshot.games.removeAll { $0.contents.isEmpty }
        scopedURLs[source.id]?.stopAccessingSecurityScopedResource()
        scopedURLs[source.id] = nil
        if case .source(let id) = selection, id == source.id {
            select(.all)
        }
        reconcileSelection()
        firstSeen = firstSeen.filter { snapshot.games.map(\.id).contains($0.key) }
        Task {
            await persistSnapshot()
            scheduleFirstSeenSave()
        }
        sourcePendingRemoval = nil
    }

    // MARK: - Scanning

    func scanAll() {
        guard !isScanning else { return }
        let targets = snapshot.sources
        guard !targets.isEmpty else {
            notice = AppNotice(level: .info, title: "还没有游戏来源", message: "先添加一个包含游戏文件的文件夹。", action: nil)
            return
        }
        scanTask = Task { await runScan(targets) }
    }

    func scanSource(_ id: String) {
        guard !isScanning else { return }
        guard let source = snapshot.sources.first(where: { $0.id == id }) else { return }
        scanTask = Task { await runScan([source]) }
    }

    private func runScan(_ targets: [LibrarySource]) async {
        isScanning = true
        scanPhase = nil
        var failures: [(name: String, message: String)] = []

        for source in targets {
            if Task.isCancelled { break }
            scanPhase = source.name
            do {
                let result = try await scanner.scan(source)
                applyScan(result, for: source)
                cacheLoaded = true
                cacheWriteAllowed = true
                await persistSnapshot()
                if !result.issues.isEmpty {
                    notice = AppNotice(
                        level: .warning,
                        title: "「\(source.name)」扫描不完整",
                        message: "已合并本次读取到的内容，并保留该来源的上次缓存；未能读取到的文件不会被当作已删除。",
                        action: .scanAll,
                        actionLabel: "重新扫描"
                    )
                }
            } catch {
                if Task.isCancelled { break }
                failures.append((source.name, error.localizedDescription))
                if let index = snapshot.sources.firstIndex(where: { $0.id == source.id }) {
                    snapshot.sources[index].availability = FileManager.default.fileExists(atPath: normalizedPath(source.url)) ? .online : .offline
                }
                let prefix = "[\(source.name)] "
                snapshot.issues.removeAll { $0.hasPrefix(prefix) }
                snapshot.issues.append(prefix + "扫描失败：\(error.localizedDescription)")
            }
        }

        isScanning = false
        scanPhase = nil
        reconcileSelection()

        if let first = failures.first {
            let extra = failures.count > 1 ? "（共 \(failures.count) 个来源失败）" : ""
            notice = AppNotice(
                level: .warning,
                title: "扫描「\(first.name)」失败",
                message: "\(first.message)\(extra)",
                action: .scanAll,
                actionLabel: "重试"
            )
        }
    }

    private func applyScan(_ result: LibrarySnapshot, for source: LibrarySource) {
        // A scan with issues means some subdirectories could not be enumerated.
        // Keep the previous cache entries for this source instead of treating
        // the partial result as an authoritative replacement.
        let isPartial = !result.issues.isEmpty
        var kept: [Game] = []
        for game in snapshot.games {
            guard gameBelongs(game, to: source) else {
                kept.append(game)
                continue
            }
            var remainder = game
            if !isPartial {
                remainder.contents.removeAll { isUnder($0.fileURL, source: source) }
            }
            if !remainder.contents.isEmpty {
                kept.append(remainder)
            }
        }

        var indexByID: [String: Int] = [:]
        for (index, game) in kept.enumerated() { indexByID[game.id] = index }

        for scanned in result.games {
            if let index = indexByID[scanned.id] {
                var existing = kept[index]
                let existingContentIDs = Set(existing.contents.map(\.id))
                existing.contents.append(contentsOf: scanned.contents.filter { !existingContentIDs.contains($0.id) })
                existing.title = scanned.title
                if let original = scanned.originalTitle { existing.originalTitle = original }
                if let cover = scanned.coverURL { existing.coverURL = cover }
                if scanned.identification == .verified { existing.identification = .verified }
                kept[index] = existing
            } else {
                indexByID[scanned.id] = kept.count
                kept.append(scanned)
            }
        }
        snapshot.games = kept

        if let index = snapshot.sources.firstIndex(where: { $0.id == source.id }) {
            snapshot.sources[index].availability = .online
        }
        let stamp = result.scannedAt ?? Date()
        if snapshot.scannedAt == nil || stamp > snapshot.scannedAt! {
            snapshot.scannedAt = stamp
        }

        let prefix = "[\(source.name)] "
        snapshot.issues.removeAll { $0.hasPrefix(prefix) }
        snapshot.issues.append(contentsOf: result.issues.map { prefix + $0 })
        if isPartial {
            snapshot.issues.append(prefix + "扫描不完整：已保留上次缓存条目，未删除未读取到的文件。")
        }
        noteFirstSeen(for: result.games, persist: true)
    }

    private func reconcileSelection() {
        let ids = Set(games.map(\.id))
        selectedGameIDs.formIntersection(ids)
        if let activeGameID, !ids.contains(activeGameID) {
            self.activeGameID = selectedGameIDs.first
        }
        if selectedGameIDs.isEmpty { activeGameID = nil }
        if let anchor = selectionAnchor, !ids.contains(anchor) { selectionAnchor = nil }
    }

    private func noteFirstSeen(for incoming: [Game], persist: Bool) {
        var changed = false
        let now = Date()
        for game in incoming where firstSeen[game.id] == nil {
            firstSeen[game.id] = now
            changed = true
        }
        let liveIDs = Set(snapshot.games.map(\.id))
        let stale = firstSeen.keys.filter { !liveIDs.contains($0) }
        if !stale.isEmpty {
            for id in stale { firstSeen[id] = nil }
            changed = true
        }
        if changed, persist { scheduleFirstSeenSave() }
    }

    private func scheduleFirstSeenSave() {
        firstSeenSaveTask?.cancel()
        let value = firstSeen
        firstSeenSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            try? await planStore.saveFirstSeen(value)
        }
    }

    // MARK: - Devices

    /// Only a single 057e:201d MTP candidate can start a read. Discovery never
    /// reports `.ready`; the read performs the actual handshake itself.
    private var mtpCandidateSignature: String? {
        guard let discovery = deviceDiscovery,
              discovery.state == .waitingForMTP else { return nil }
        let candidates = discovery.devices.filter {
            $0.vendorID == 0x057e && $0.productID == 0x201d
        }
        guard candidates.count == 1 else { return nil }
        return candidates.map { "\($0.vendorID):\($0.productID)" }.joined(separator: ",")
    }

    var canReadInventory: Bool {
        mtpCandidateSignature != nil && !isReadingInventory && !isDiscovering
    }

    var inventoryIsCurrentSession: Bool {
        guard inventory != nil, let signature = inventorySessionSignature else { return false }
        return signature == mtpCandidateSignature
    }

    func refreshDevices() async {
        guard !isDiscovering, !isReadingInventory else { return }
        isDiscovering = true
        // Discovery exposes only VID/PID, not a stable session identity. A new USB
        // enumeration cannot prove this is the same device that supplied the last
        // inventory, even when the candidate signature looks identical.
        inventory = nil
        inventorySessionSignature = nil
        let result = await deviceService.discover()
        deviceDiscovery = result
        isDiscovering = false
    }

    func readInventory() async {
        guard !isReadingInventory else { return }
        guard canReadInventory, let signature = mtpCandidateSignature else {
            notice = AppNotice(
                level: .warning,
                title: "未检测到可读取的 MTP 候选设备",
                message: "请只连接一台 Switch 并用数据线连接，打开 DBI 的 MTP 响应模式后重新检测。读取会在握手成功后才产生清单。",
                action: .refreshDevices,
                actionLabel: "重新检测"
            )
            return
        }
        isReadingInventory = true
        do {
            let value = try await inventoryReader.readInventory()
            inventory = value
            inventorySessionSignature = signature
            if !value.isComplete {
                notice = AppNotice(
                    level: .warning,
                    title: "已安装清单不完整",
                    message: "已读取 \(value.records.count) 条记录，但遍历未完成。安装状态只在存在正向记录时显示。",
                    action: .readInventory,
                    actionLabel: "重新读取"
                )
            }
        } catch {
            inventory = nil
            inventorySessionSignature = nil
            notice = AppNotice(
                level: .error,
                title: "读取已安装内容失败",
                message: error.localizedDescription,
                action: .readInventory,
                actionLabel: "重试"
            )
        }
        isReadingInventory = false
    }

    // MARK: - Installation plan

    func isInPlan(_ gameID: String) -> Bool {
        plan.contains { $0.gameID == gameID }
    }

    func planItem(for gameID: String) -> PlanItem? {
        plan.first { $0.gameID == gameID }
    }

    func addToQueue(_ game: Game) {
        addToQueue(game, persist: true)
    }

    private func addToQueue(_ game: Game, persist: Bool) {
        guard !game.contents.isEmpty else {
            notice = AppNotice(level: .info, title: "没有可加入的本地内容", message: "该条目没有可用于安装计划的文件。")
            return
        }
        if let index = plan.firstIndex(where: { $0.gameID == game.id }) {
            let existing = plan[index]
            var refreshed = PlanItem(game: game, target: existing.target, note: existing.note, addedAt: existing.addedAt)
            if !refreshed.contents.isEmpty {
                let included = Set(existing.contents.filter(\.included).map(\.id))
                for contentIndex in refreshed.contents.indices {
                    refreshed.contents[contentIndex].included = included.contains(refreshed.contents[contentIndex].id)
                }
                plan[index] = refreshed
            }
        } else {
            plan.append(PlanItem(game: game))
        }
        if persist { schedulePlanSave() }
    }

    func addSelectedToQueue() {
        for game in selectedGames { addToQueue(game, persist: false) }
        schedulePlanSave()
    }

    func updatePlanTarget(_ id: String, target: InstallTarget) {
        guard let index = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[index].target = target
        schedulePlanSave()
    }

    func setPlanContentIncluded(_ itemID: String, contentID: String, included: Bool) {
        guard let itemIndex = plan.firstIndex(where: { $0.id == itemID }),
              let contentIndex = plan[itemIndex].contents.firstIndex(where: { $0.id == contentID }) else { return }
        plan[itemIndex].contents[contentIndex].included = included
        schedulePlanSave()
    }

    func updatePlanNote(_ id: String, note: String) {
        guard let index = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[index].note = note
        schedulePlanSave()
    }

    func movePlanItem(_ id: String, direction: Int) {
        guard let index = plan.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard plan.indices.contains(target) else { return }
        plan.swapAt(index, target)
        schedulePlanSave()
    }

    func removePlanItem(_ id: String) {
        plan.removeAll { $0.id == id }
        schedulePlanSave()
    }

    func clearPlan() {
        plan.removeAll()
        schedulePlanSave(immediate: true)
    }

    private func schedulePlanSave(immediate: Bool = false) {
        planSaveTask?.cancel()
        let items = plan
        planSaveTask = Task {
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            do {
                try await planStore.savePlan(items)
            } catch {
                self.notice = AppNotice(
                    level: .warning,
                    title: "安装计划保存失败",
                    message: "计划仍保留在界面中：\(error.localizedDescription)",
                    action: .savePlan,
                    actionLabel: "重试"
                )
            }
        }
    }

    var planSummaryText: String {
        guard !plan.isEmpty else { return "SwitchShelf 安装队列为空。" }
        var lines = ["SwitchShelf 本地安装计划", "生成时间：\(absoluteTime(.now))", "目标：仅本地计划，未执行安装", ""]
        for (index, item) in plan.enumerated() {
            lines.append("\(index + 1). \(item.title) · \(item.target.label) · \(formatByteCount(item.byteCount))")
            for content in item.includedContents {
                lines.append("   - \(content.kind.label) \(content.version ?? "版本未知") \(content.fileName) \(formatByteCount(content.byteCount))")
            }
            if !item.note.isEmpty { lines.append("   备注：\(item.note)") }
        }
        return lines.joined(separator: "\n")
    }

    func copyPlanSummary() {
        guard !plan.isEmpty else {
            notice = AppNotice(level: .info, title: "安装队列为空", message: "添加游戏后再复制计划摘要。")
            return
        }
        copyToPasteboard(planSummaryText)
    }

    func exportPlan() {
        guard !plan.isEmpty else {
            notice = AppNotice(level: .info, title: "安装队列为空", message: "添加游戏后再导出计划。")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(plan)
            let panel = NSSavePanel()
            panel.title = "导出安装计划"
            panel.nameFieldStringValue = "SwitchShelf-安装计划.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            notice = AppNotice(level: .error, title: "安装计划导出失败", message: error.localizedDescription)
        }
    }

    // MARK: - Finder & clipboard

    func revealInFinder(_ url: URL) {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            notice = AppNotice(
                level: .error,
                title: "无法在访达中显示",
                message: "文件已不可用，来源可能离线或已移动：\(url.lastPathComponent)",
                action: .refreshAvailability,
                actionLabel: "刷新来源状态"
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealGame(_ game: Game) {
        guard let url = game.revealURL else {
            notice = AppNotice(level: .info, title: "没有可显示的文件", message: "该条目没有本地内容路径。")
            return
        }
        revealInFinder(url)
    }

    func revealSource(_ source: LibrarySource) {
        if FileManager.default.fileExists(atPath: normalizedPath(source.url)) {
            NSWorkspace.shared.open(source.url)
        } else {
            notice = AppNotice(
                level: .warning,
                title: "来源当前离线",
                message: "「\(source.name)」当前不可访问，缓存条目仍然保留。重新挂载后可再次扫描。",
                action: .refreshAvailability,
                actionLabel: "刷新状态"
            )
        }
    }

    func openAppSupport() {
        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(appDirectory) {
                throw CocoaError(.fileNoSuchFile)
            }
        } catch {
            notice = AppNotice(level: .error, title: "无法打开应用数据目录", message: error.localizedDescription)
        }
    }

    func revealCache() {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            notice = AppNotice(level: .info, title: "尚无本地缓存", message: "完成一次扫描后会在应用数据目录生成缓存。", action: .openAppSupport, actionLabel: "打开目录")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([cacheURL])
    }

    func cacheByteCount() async -> Int64 {
        let path = cacheURL.path
        return await Task.detached(priority: .utility) { () -> Int64 in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return 0 }
            return size.int64Value
        }.value
    }

    func copyTitleID(_ titleID: String?) {
        guard let value = normalizedTitleID(titleID) else {
            notice = AppNotice(level: .info, title: "没有 Title ID", message: "该内容没有可信的 Title ID 可复制。")
            return
        }
        copyToPasteboard(value)
    }

    func copyPath(_ url: URL) {
        copyToPasteboard(url.path)
    }

    func copyDiagnostics() {
        let device: String
        if let deviceDiscovery {
            device = "\(deviceDiscovery.state.rawValue)：\(deviceDiscovery.message)"
        } else {
            device = "尚未检测"
        }
        let inventoryLine: String
        if let inventory {
            inventoryLine = "记录 \(inventory.records.count) 条 · \(inventory.isComplete ? "完整" : "不完整") · 读取于 \(absoluteTime(inventory.observedAt))"
        } else {
            inventoryLine = "未读取"
        }
        let lines = [
            "SwitchShelf 诊断摘要",
            "生成时间：\(absoluteTime(.now))",
            "游戏：\(games.count)；本地内容：\(totalContentCount)；来源：\(sourceCount)（在线 \(onlineSourceCount)）",
            "最后扫描：\(absoluteTime(snapshot.scannedAt))",
            "安装计划：\(plan.count) 项，\(formatByteCount(planTotalBytes))",
            "设备：\(device)",
            "已安装清单：\(inventoryLine)",
            "扫描问题：\(scanIssues.count) 条",
            "缓存：\(cacheLoaded ? "已载入" : "未载入") \(cacheURL.path)",
            "应用数据：\(appDirectory.path)"
        ]
        copyToPasteboard(lines.joined(separator: "\n"))
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Notice actions

    func perform(_ action: AppNotice.Action) {
        notice = nil
        switch action {
        case .scanAll:
            scanAll()
        case .refreshDevices:
            Task { await refreshDevices() }
        case .readInventory:
            Task { await readInventory() }
        case .reloadCache:
            Task { await reloadCache() }
        case .savePlan:
            schedulePlanSave(immediate: true)
        case .refreshAvailability:
            refreshAvailability()
        case .openAppSupport:
            openAppSupport()
        }
    }

    // MARK: - Helpers

    private func gameBelongs(_ game: Game, to source: LibrarySource) -> Bool {
        game.contents.contains { isUnder($0.fileURL, source: source) }
    }

    private func isUnder(_ url: URL, source: LibrarySource) -> Bool {
        let root = normalizedPath(source.url)
        let path = normalizedPath(url)
        return path == root || path.hasPrefix(root + "/")
    }

    private func normalizedPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static var initialSourceURL: URL {
        URL(fileURLWithPath: "/Volumes/switch 游戏包", isDirectory: true)
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwitchShelf", isDirectory: true)
    }
}
