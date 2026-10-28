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
    private(set) var inventoryComparison: String?
    private(set) var inventoryCacheSaved = false
    private(set) var inventorySessionSignature: String?
    private(set) var deviceDiscovery: DeviceDiscovery?
    private(set) var wifi = WiFiFTPSnapshot.notConnected
    var wifiHost = ""
    var wifiPort = ""
    private(set) var rememberedWiFiHost: String?
    private(set) var isWiFiBusy = false
    private(set) var cacheLoaded = false
    private(set) var isBootstrapped = false
    private(set) var isScanning = false
    private(set) var scanPhase: String?
    private(set) var isDiscovering = false
    private(set) var isReadingInventory = false
    private(set) var isCheckingPlan = false
    private(set) var preparation: SphairaPreflightResult?
    private(set) var isInstalling = false
    private(set) var isVerifyingInstall = false
    private(set) var installListConfirmed = false
    private(set) var completedInstallGameIDs: Set<String> = []
    private(set) var verificationDetail: String?
    private(set) var isReviewingInstall = false
    var installationReview: SphairaBatchReview?
    private(set) var installStatuses: [SphairaBatchStatus] = []

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
    var detailGameID: String?
    var showConnectionGuide = false
    private(set) var isPreparingInstallation = false
    private var omittedUpdates: [String: [LocalContent]] = [:]
    var searchFocusToken = 0
    var notice: AppNotice?
    var sourcePendingRemoval: LibrarySource?

    // MARK: Services
    @ObservationIgnored private let scanner: any LibraryScanning = LibraryScanner()
    @ObservationIgnored private let discoverDevice: @Sendable () async -> DeviceDiscovery
    @ObservationIgnored private let wifiClient = WiFiFTPClient()
    @ObservationIgnored private let inventoryReader: BoundedInventoryReader
    @ObservationIgnored private let preflightService = SphairaPreflightService()
    @ObservationIgnored private let mtpInstaller = SphairaInstaller()
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var reviewedPlan: SphairaPreflightInput?
    @ObservationIgnored private var repository: (any LibraryPersisting)?
    @ObservationIgnored private let appDirectory: URL
    @ObservationIgnored private let planStore: LocalPlanStore
    @ObservationIgnored private let inventoryCache: InventoryCache
    @ObservationIgnored private var scopedURLs: [String: URL] = [:]
    @ObservationIgnored private var selectionAnchor: String?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var planSaveTask: Task<Void, Never>?
    @ObservationIgnored private var firstSeenSaveTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapStarted = false
    @ObservationIgnored private var cacheWriteAllowed = false
    @ObservationIgnored private var deviceMonitorTask: Task<Void, Never>?
    /// In-flight USB descriptor poll. Ignored by observation so a steady connection
    /// does not republish the status pill or the staging list.
    @ObservationIgnored private var devicePollActive = false
    @ObservationIgnored private var soundedSession: String?
    @ObservationIgnored private var automaticAttempts = 0
    @ObservationIgnored private var lastAutomaticAttempt: Date?
    @ObservationIgnored private var automaticReadBlocked = false
    @ObservationIgnored private var cachedInventory: InstalledInventory?
    @ObservationIgnored private var wasOpenMTPRunning = false

    init(appDirectory: URL? = nil, inventoryReader: BoundedInventoryReader = BoundedInventoryReader(),
         discoverDevice: @escaping @Sendable () async -> DeviceDiscovery = { await DeviceService().discover() }) {
        self.inventoryReader = inventoryReader
        self.discoverDevice = discoverDevice
        let defaults = UserDefaults.standard
        let directory = appDirectory ?? Self.applicationSupportDirectory()
        self.appDirectory = directory
        self.planStore = LocalPlanStore(directory: directory)
        self.inventoryCache = InventoryCache(directory: directory)
        self.layout = LibraryLayout(rawValue: defaults.string(forKey: "SwitchShelf.layout") ?? "") ?? .grid
        self.sortOrder = SortOrder(rawValue: defaults.string(forKey: "SwitchShelf.sortOrder") ?? "") ?? .recent
        let storedCover = defaults.double(forKey: "SwitchShelf.coverSize")
        self.coverSize = storedCover >= 120 ? storedCover : 172
        self.rememberedWiFiHost = WiFiFTPRememberedHost.storedHost(in: defaults)
        self.wifiHost = WiFiFTPRememberedHost.hostFieldForLaunch(currentField: "", defaults: defaults)
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
        case .wifi: "无线连接"
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
            return "\(plan.count) 项计划 · \(formatByteCount(planTotalBytes)) · " + (isInstalling ? "正在发送队列" : "点击后立即发送")
        case .device:
            return deviceSubtitle
        case .wifi:
            return wifiSubtitle
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
            let recent = recentGameIDs
            result = games.filter { recent.contains($0.id) }
        case .unidentified:
            result = games.filter { $0.identification.isPending }
        case .source(let id):
            guard let source = snapshot.sources.first(where: { $0.id == id }) else {
                result = []
                break
            }
            result = games.filter { gameBelongs($0, to: source) }
        case .queue, .device, .wifi, .maintenance:
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
                let onDevice = state == .installed || state == .partial
                return installFilter == .installed ? onDevice : !onDevice
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
        if isReadingInventory { return "正在通过 MTP 读取设备清单" }
        guard let deviceDiscovery else { return "尚未检测 USB 设备" }
        return deviceDiscovery.message
    }

    var wifiSubtitle: String {
        if wifi.host.isEmpty { return "DBI FTP · 与 USB 分开" }
        let port = wifi.port.map(String.init) ?? "端口未定"
        return "\(wifi.phase.label) · \(wifi.host):\(port)"
    }

    var wifiBlocksUSB: Bool {
        isWiFiBusy || wifi.phase == .connecting || wifi.phase == .connected
    }

    var installedGameCount: Int {
        guard inventory != nil else { return 0 }
        return games.filter { assessment(for: $0).state == .installed }.count
    }

    /// Games with installed or partial evidence in the current USB session.
    var locallyMatchedGameCount: Int {
        guard inventoryIsCurrentSession else { return 0 }
        return games.filter {
            let state = assessment(for: $0).state
            return state == .installed || state == .partial
        }.count
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
        case .device, .wifi, .maintenance: nil
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
    func showWiFi() { select(.wifi) }
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

    var detailGame: Game? { games.first { $0.id == detailGameID } }

    func openGameDetails(_ game: Game) { detailGameID = game.id }
    func closeGameDetails() { detailGameID = nil }

    var installationPlanLocked: Bool {
        isInstalling || isPreparingInstallation || isReviewingInstall || isVerifyingInstall || installationReview != nil
    }

    func handleGridTap(_ game: Game, modifiers: NSEvent.ModifierFlags? = nil) {
        let flags = modifiers ?? NSApp.currentEvent?.modifierFlags ?? []
        // Plain selection must not re-filter and locale-sort the entire library
        // on the same main-thread turn that starts the native inspector animation.
        let ordered = flags.contains(.shift) ? filteredGames.map(\.id) : []

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
        if flags.contains(.shift) {
            addSelectedToQueue()
        } else if selectedGameIDs.contains(game.id) {
            addToQueue(game)
        }
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

    func assessment(for content: LocalContent, in game: Game) -> InstallationAssessment {
        guard game.contents.contains(where: { $0.id == content.id }) else {
            return InstallationAssessment(state: .unknown, explanation: "这项内容不属于当前游戏，不推断安装状态。")
        }
        return InstallationAssessor.assess(
            content,
            in: game,
            inventory: inventory,
            isCurrentSession: inventoryIsCurrentSession
        )
    }

    // MARK: - Bootstrap & cache

    func bootstrap() async {
        guard !bootstrapStarted else { return }
        bootstrapStarted = true
        cachedInventory = await inventoryCache.load()
        inventoryCacheSaved = cachedInventory != nil
        inventory = cachedInventory
        // USB discovery must not wait for a slow or offline SMB source.
        startDeviceMonitoring()

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
        // Choosing an existing directory is also the recovery path for lost
        // access. Refresh its bookmark before rescanning, retaining its ID and
        // cache instead of treating the selection as a no-op.
        let existingIndex = snapshot.sources.firstIndex { normalizedPath($0.url) == path }
        let sourceID = existingIndex.map { snapshot.sources[$0].id } ?? UUID().uuidString
        let didAccess = standardized.startAccessingSecurityScopedResource()
        if didAccess {
            scopedURLs[sourceID]?.stopAccessingSecurityScopedResource()
            scopedURLs[sourceID] = standardized
        }
        if let existingIndex {
            snapshot.sources[existingIndex].url = standardized
            snapshot.sources[existingIndex].availability = .online
        } else {
            snapshot.sources.append(LibrarySource(
                id: sourceID,
                url: standardized,
                name: standardized.lastPathComponent.isEmpty ? "游戏文件夹" : standardized.lastPathComponent,
                availability: .online
            ))
        }

        var bookmarkError: String?
        do {
            let bookmark = try standardized.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            if let index = snapshot.sources.firstIndex(where: { $0.id == sourceID }) {
                snapshot.sources[index].bookmark = bookmark
            }
        } catch {
            bookmarkError = error.localizedDescription
        }

        await persistSnapshot()
        select(.source(sourceID))

        if let bookmarkError {
            notice = AppNotice(
                level: .info,
                title: existingIndex == nil ? "来源已添加" : "来源已重新选择",
                message: "但无法保存长期访问书签，重新启动后若无法访问，需要再次添加该文件夹。\(bookmarkError)"
            )
        }

        scanSource(sourceID)
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
        if let detailGameID, !ids.contains(detailGameID) { self.detailGameID = nil }
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
              [.waitingForMTP, .ready].contains(discovery.state) else { return nil }
        let candidates = discovery.devices.filter {
            $0.vendorID == 0x057e && $0.productID == 0x201d
        }
        guard candidates.count == 1, discovery.devices.filter({ $0.vendorID == 0x057e && ($0.productID == 0x201d || $0.productID == 0x3000) }).count == 1 else { return nil }
        return candidates[0].id
    }

    var canReadInventory: Bool {
        mtpCandidateSignature != nil && !automaticReadBlocked && !isReadingInventory && !isDiscovering && !installationPlanLocked && !wifiBlocksUSB
    }

    var inventoryIsCurrentSession: Bool {
        guard inventory != nil, let signature = inventorySessionSignature else { return false }
        return signature == mtpCandidateSignature
    }

    /// Poll only USB descriptors. MTP is opened at most twice for a new candidate,
    /// with a pause between attempts, and never while another app operation uses it.
    private func startDeviceMonitoring() {
        guard deviceMonitorTask == nil else { return }
        deviceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.monitorDevice()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func monitorDevice() async {
        guard !devicePollActive, !isDiscovering, !isReadingInventory, !wifiBlocksUSB else { return }
        guard !installationPlanLocked || isVerifyingInstall else { return }
        devicePollActive = true
        defer { devicePollActive = false }
        let previous = mtpCandidateSignature
        let result = await discoverDevice()
        guard !isInstalling, !wifiBlocksUSB else { return }
        // Keep successful MTP status while the same registry entry remains present.
        let newIDs = result.devices.map(\.id).sorted()
        let oldIDs = deviceDiscovery?.devices.map(\.id).sorted()
        if newIDs != oldIDs || result.state == .error || deviceDiscovery?.state == .error {
            deviceDiscovery = result
            inventory = cachedInventory
            inventorySessionSignature = nil
            inventoryComparison = nil
            soundedSession = nil
            automaticAttempts = 0
            lastAutomaticAttempt = nil
            if !automaticReadBlocked, notice?.action == .readInventory || notice?.action == .refreshDevices {
                notice = nil
            }
        } else if deviceDiscovery == nil {
            deviceDiscovery = result
        }
        guard !isVerifyingInstall, let signature = mtpCandidateSignature, !automaticReadBlocked,
              !inventoryIsCurrentSession else { return }
        if openMTPIsRunning {
            wasOpenMTPRunning = true
            deviceDiscovery?.message = "OpenMTP 正在运行；请完整退出，应用将自动尝试连接。"
            return
        }
        if wasOpenMTPRunning {
            wasOpenMTPRunning = false
            automaticAttempts = 0
            lastAutomaticAttempt = nil
        }
        if signature != previous {
            automaticAttempts = 0
            lastAutomaticAttempt = nil
        }
        guard automaticAttempts < 2,
              lastAutomaticAttempt.map({ Date().timeIntervalSince($0) >= 15 }) ?? true else { return }
        automaticAttempts += 1
        lastAutomaticAttempt = Date()
        _ = await readInventory(automatically: true)
    }

    var deviceSessionOverview: DeviceSessionOverview {
        DeviceSessionOverview.make(
            discovery: deviceDiscovery,
            inventory: inventory,
            inventoryBelongsToCurrentSession: inventoryIsCurrentSession,
            isDiscovering: isDiscovering,
            isReadingInventory: isReadingInventory
        )
    }

    func refreshDevices() async {
        guard !isDiscovering, !isReadingInventory, !installationPlanLocked else { return }
        if wifiBlocksUSB {
            notice = wifiBlocksUSBNotice
            return
        }
        isDiscovering = true
        defer { isDiscovering = false }
        await waitForDevicePoll()
        devicePollActive = true
        defer { devicePollActive = false }
        let previous = mtpCandidateSignature
        let result = await discoverDevice()
        deviceDiscovery = result
        if previous != mtpCandidateSignature {
            inventory = cachedInventory
            inventorySessionSignature = nil
            soundedSession = nil
        }
    }

    private func waitForDevicePoll() async {
        while devicePollActive, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Detect USB, then read when there is a single 057e:201d candidate and OpenMTP is not running.
    /// A failed read leaves the last cached snapshot available as historical data.
    func detectAndRead(announceWhenMissing: Bool = true) async {
        guard !isDiscovering, !isReadingInventory, !installationPlanLocked else { return }
        if wifiBlocksUSB {
            if announceWhenMissing { notice = wifiBlocksUSBNotice }
            return
        }
        if openMTPIsRunning {
            if deviceDiscovery == nil {
                await refreshDevices()
            }
            presentOpenMTPPreflight()
            return
        }
        await refreshDevices()
        guard !isInstalling else { return }
        if openMTPIsRunning {
            presentOpenMTPPreflight()
            return
        }
        guard mtpCandidateSignature != nil else {
            if announceWhenMissing {
                notice = AppNotice(
                    level: .warning,
                    title: "未检测到可读取的 MTP 候选设备",
                    message: "请连接一台 Switch，开启 sphaira 的 MTP 或 DBI 的 Run MTP responder 后再次检测并读取。",
                    action: .refreshDevices,
                    actionLabel: "检测并读取"
                )
            }
            return
        }
        _ = await readInventory()
        if openMTPIsRunning {
            presentOpenMTPPreflight()
        }
    }

    @discardableResult
    func readInventory(forVerification: Bool = false, automatically: Bool = false, timeoutSeconds: Int = 60) async -> Bool {
        guard !Task.isCancelled, !automaticReadBlocked, !isReadingInventory, !isInstalling else { return false }
        if wifiBlocksUSB {
            notice = wifiBlocksUSBNotice
            return false
        }
        guard canReadInventory || (forVerification && isVerifyingInstall && !isDiscovering), let signature = mtpCandidateSignature else {
            if !isVerifyingInstall {
                notice = AppNotice(
                    level: .warning,
                    title: "未检测到可读取的 MTP 候选设备",
                    message: "请连接一台 Switch，开启 sphaira 的 MTP 或 DBI 的 Run MTP responder 后再次检测并读取。",
                    action: .refreshDevices,
                    actionLabel: "检测并读取"
                )
            }
            return false
        }
        // A third-party MTP client does not participate in our advisory lease.
        // This is a preflight hint, not a claim about OS interface ownership.
        if openMTPIsRunning {
            presentOpenMTPPreflight()
            return false
        }
        isReadingInventory = true
        defer { isReadingInventory = false }
        let preservedInventory = inventory
        let preservedSignature = inventorySessionSignature
        if !isVerifyingInstall { notice = nil }
        var succeeded = false
        do {
            let value = try await inventoryReader.readInventory(timeoutSeconds: timeoutSeconds)
            // A disconnect/reconnect during the helper read must never attach its
            // result to a different USB registry entry, even with the same VID/PID.
            let latest = await discoverDevice()
            deviceDiscovery = latest
            guard mtpCandidateSignature == signature else {
                inventory = cachedInventory
                inventorySessionSignature = nil
                soundedSession = nil
                automaticAttempts = 0
                lastAutomaticAttempt = nil
                return false
            }
            inventoryComparison = compareInventory(cachedInventory, with: value)
            inventory = value
            inventorySessionSignature = signature
            let sources = value.mtpEvidence?.inventoryStorageNames.joined(separator: "、") ?? ""
            deviceDiscovery?.state = .ready
            deviceDiscovery?.message = "MTP 已连接" + (sources.isEmpty ? "" : " · \(sources)")
                + (value.isComplete ? " · 已读取完整内容清单。" : " · 安装清单尚未完整确认。")
            if !isVerifyingInstall, soundedSession != signature {
                NSSound(named: "Glass")?.play()
                soundedSession = signature
            }
            if value.isComplete || cachedInventory == nil {
                cachedInventory = value
                do {
                    try await inventoryCache.save(value)
                    inventoryCacheSaved = true
                }
                catch {
                    inventoryCacheSaved = false
                    notice = AppNotice(level: .warning, title: "设备清单未能保存到本机", message: "当前清单仍可查看；请检查应用数据目录后重新读取。", action: .openAppSupport, actionLabel: "打开目录")
                }
            }
            if !isVerifyingInstall && !value.isComplete {
                let missingSource = value.mtpEvidence?.inventoryStorageNames.isEmpty == true
                notice = AppNotice(
                    level: .warning,
                    title: missingSource ? "MTP 已连接，未提供游戏清单入口" : "已连接，清单仍有未确认内容",
                    message: missingSource
                        ? "已取得设备存储列表，但没有 Games 或 Installed games。可在下方查看实际入口；这不代表设备没有游戏。"
                        : "已读取 \(value.records.count) 条记录，部分内容或覆盖范围尚未确认。请查看清单中的具体问题。",
                    action: .readInventory,
                    actionLabel: "重新读取"
                )
            }
            if isVerifyingInstall {
                verificationDetail = value.isComplete ? "已取得完整 Games 清单，正在核对所选内容与版本。" : "Games 清单尚未完整，暂不确认安装成功。"
            }
            succeeded = true
            // An intentional manual read can finish a previously unconfirmed
            // batch after the user refreshes the device-side Games projection.
            if !forVerification, !automatically, !isVerifyingInstall, transferredQueueShowsInstalled() {
                isVerifyingInstall = true
                await finishInstallVerification(confirmed: true)
            }
        } catch {
            if isVerifyingInstall { verificationDetail = error.localizedDescription }
            soundedSession = nil
            if let probeError = error as? ProbeError, case .previousProcessUnverified = probeError {
                automaticReadBlocked = true
            }
            let latest = await discoverDevice()
            deviceDiscovery = latest
            guard mtpCandidateSignature == signature else {
                inventory = cachedInventory
                inventorySessionSignature = nil
                soundedSession = nil
                automaticAttempts = 0
                lastAutomaticAttempt = nil
                return false
            }
            if preservedSignature == signature, let preservedInventory {
                inventory = cachedInventory ?? preservedInventory
                inventorySessionSignature = nil
                deviceDiscovery?.state = .waitingForMTP
                deviceDiscovery?.message = retainedInventoryMessage(preservedInventory)
                if !isVerifyingInstall {
                    notice = AppNotice(
                        level: .error,
                        title: "重新读取失败，已保留上次清单",
                        message: "\(error.localizedDescription) USB 候选未变化，已保留上次成功清单。",
                        action: .readInventory,
                        actionLabel: "重试"
                    )
                }
            } else {
                inventory = cachedInventory
                inventorySessionSignature = nil
                deviceDiscovery?.state = .waitingForMTP
                deviceDiscovery?.message = "已发现 USB 候选设备，本次 MTP 读取未成功；请检查 MTP 模式和其他客户端。"
                if !isVerifyingInstall {
                    notice = AppNotice(
                        level: .error,
                        title: "读取已安装内容失败",
                        message: error.localizedDescription,
                        action: .readInventory,
                        actionLabel: "重试"
                    )
                }
            }
        }
        return succeeded
    }

    private func compareInventory(_ old: InstalledInventory?, with new: InstalledInventory) -> String? {
        guard let old else { return nil }
        switch InventorySnapshotComparison.compare(old, new) {
        case .incomplete:
            return old.isComplete && !new.isComplete
                ? "本次清单不完整，无法可靠比较增减；已保留上次完整缓存。"
                : "至少一份清单不完整，无法可靠比较增减。"
        case let .changes(added, missing):
            return "与上次缓存比较：新增 \(added) 条，未再出现 \(missing) 条。设备身份未核实，变化不一定发生在同一台主机。"
        }
    }

    func inventoryDirectoryGroups(from records: [InstalledRecord]) -> [InventoryDirectoryGroup] {
        let buckets = Dictionary(grouping: records, by: { directoryIdentity(for: $0) })
        return buckets.map { key, items in
            let sorted = items.sorted { left, right in
                if left.kind.order != right.kind.order { return left.kind.order < right.kind.order }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return InventoryDirectoryGroup(
                id: key,
                directoryName: directoryTitle(for: key),
                records: sorted,
                localGameTitles: localGameTitles(matching: sorted)
            )
        }
        .sorted { $0.directoryName.localizedStandardCompare($1.directoryName) == .orderedAscending }
    }

    private var openMTPIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "io.ganeshrvel.openmtp" }
    }

    private func presentOpenMTPPreflight() {
        inventory = cachedInventory ?? inventory
        inventorySessionSignature = nil
        deviceDiscovery?.state = .waitingForMTP
        if inventory == nil {
            deviceDiscovery?.message = "OpenMTP 正在运行；请完整退出后读取，避免两个客户端同时访问设备。"
        } else {
            deviceDiscovery?.message = "OpenMTP 正在运行，未重新读取。已保留上次清单，退出后可重新连接。"
        }
        notice = AppNotice(
            level: .warning,
            title: "请先退出 OpenMTP",
            message: inventory == nil
                ? "OpenMTP 可能仍持有 MTP 会话。请使用菜单中的退出功能，再返回检测并读取。"
                : "OpenMTP 可能仍持有 MTP 会话。已保留上次清单，退出后再重新读取。"
        )
    }

    private func retainedInventoryMessage(_ inventory: InstalledInventory) -> String {
        let sources = inventory.mtpEvidence?.inventoryStorageNames.joined(separator: "、") ?? ""
        return "本次读取未成功，USB 候选未变化，已保留上次清单"
            + (sources.isEmpty ? "" : " · \(sources)")
            + (inventory.isComplete ? " · 清单完整。" : " · 清单尚未完整确认。")
    }

    /// Game directory is the first folder under the storage name. Do not use the human
    /// directory title or Title ID arithmetic to decide which local game it is.
    private func directoryIdentity(for record: InstalledRecord) -> String {
        let parts = record.objectPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count >= 3 { return "\(parts[0])/\(parts[1])" }
        if parts.count == 2 { return parts[0] }
        return record.objectPath.isEmpty ? record.id : record.objectPath
    }

    private func directoryTitle(for key: String) -> String {
        key.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? key
    }

    private func localGameTitles(matching records: [InstalledRecord]) -> [String] {
        var titles: [String] = []
        var seen = Set<String>()
        for record in records {
            guard record.kind != .unknown, let titleID = InstallationAssessor.normalizedID(record.titleID) else { continue }
            for game in games where game.identification == .matched || game.identification == .verified {
                let matches = game.contents.contains { content in
                    content.kind == record.kind && InstallationAssessor.normalizedID(content.titleID) == titleID
                }
                if matches, seen.insert(game.id).inserted {
                    titles.append(game.title)
                }
            }
        }
        return titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - Installation plan

    private var preflightInput: SphairaPreflightInput {
        let matches = Dictionary(grouping: snapshot.games.flatMap(\.contents), by: \.id)
        return SphairaPreflightInput(items: plan.map { item in
            SphairaPreflightItem(id: item.id, intendedTarget: item.target.rawValue, entries: item.contents.enumerated().sorted { a, b in
                a.element.kind.order == b.element.kind.order ? a.offset < b.offset : a.element.kind.order < b.element.kind.order
            }.map { _, content in
                // An ID is opaque: only a unique current LocalContent mapping supplies a URL.
                let source = matches[content.id]?.count == 1 ? matches[content.id]?.first : nil
                let sourceOnline = source.map { local in
                    local.availability == .online && snapshot.sources.contains { librarySource in
                        librarySource.availability == .online && isUnder(local.fileURL, source: librarySource)
                    }
                } ?? false
                return SphairaPreflightEntry(
                    id: content.id, name: content.fileName, expectedBytes: content.byteCount,
                    included: content.included, sourceURL: source?.fileURL,
                    sourceAvailable: sourceOnline, snapshotBytes: source?.byteCount
                )
            })
        })
    }

    var preparationIsCurrent: Bool {
        preparation?.isCurrent(for: preflightInput) == true
    }

    func checkPlan() async {
        guard !isCheckingPlan, !isInstalling else { return }
        let input = preflightInput
        isCheckingPlan = true
        let result = await preflightService.check(input)
        preparation = result
        isCheckingPlan = false
    }

    // MARK: - Reviewed sphaira installation queue

    private func updates(for item: PlanItem) -> [LocalContent] {
        let ids = Set(item.contents.filter { $0.kind == .update }.map(\.id))
        return games.first { $0.id == item.gameID }?.contents.filter { ids.contains($0.id) } ?? []
    }

    func needsUpdateChoice(_ item: PlanItem) -> Bool {
        if BaseSelection.includesIntegratedBase(item.includedContents.map { ($0.kind, $0.format) }) {
            return false
        }
        let candidates = updates(for: item)
        return InstallContentDefaults.needsUpdateChoice(in: candidates)
            && !item.includedContents.contains { $0.kind == .update }
            && omittedUpdates[item.id] != candidates
    }

    func baseSelectionReminder(_ item: PlanItem) -> String? {
        let bases = item.contents.filter { $0.kind == .base }
        let included = item.includedContents
        let includedBases = included.filter { $0.kind == .base }
        if BaseSelection.integratedPackageHasCompany(included.map { ($0.kind, $0.format) }) {
            return "XCI 整合包要单独安装。请取消其他本体、更新和 DLC。"
        }
        if included.count == 1, included[0].kind == .base, included[0].format == .xci, item.contents.count > 1 {
            return "已默认只安装 XCI 整合包。其他本体、更新和 DLC 不会一起发送。"
        }
        if bases.count > 1, includedBases.count != 1 {
            return "有多个本体。请只勾选一个；XCI 是整合包，NSP 是单独的本体。"
        }
        return nil
    }

    func omitUpdatesForThisInstallation(_ id: String) {
        guard !installationPlanLocked, let item = plan.first(where: { $0.id == id }) else { return }
        omittedUpdates[id] = updates(for: item)
    }

    func setAllPlanTargets(_ target: InstallTarget) {
        guard !installationPlanLocked else { return }
        for index in plan.indices { plan[index].target = target }
        schedulePlanSave()
    }

    var installationConnectionBlocker: String? {
        if automaticReadBlocked { return "上次 USB 探针退出未确认，请重启应用并检查设备后再安装。" }
        if wifiBlocksUSB { return "请先断开无线 FTP，再使用 USB 安装。" }
        if openMTPIsRunning { return "请完整退出 OpenMTP 等其他 MTP 客户端。" }
        if isReadingInventory || isDiscovering { return "正在检测或读取设备，请稍候。" }
        if isScanning { return "正在扫描来源，请等待文件清单稳定后再安装。" }
        if mtpCandidateSignature == nil { return "尚未发现单台 Switch MTP 候选设备，请连接数据线并开启 sphaira MTP。" }
        return nil
    }

    var canBeginStagedInstallation: Bool {
        !plan.isEmpty && !installationPlanLocked && !isCheckingPlan
            && plan.contains { !$0.includedContents.isEmpty }
            && installationConnectionBlocker == nil && queueValidationIssues.isEmpty
    }

    func beginStagedInstallation() async {
        guard canBeginStagedInstallation else {
            showConnectionGuide = installationConnectionBlocker != nil
            return
        }
        closeGameDetails()
        showConnectionGuide = false
        isPreparingInstallation = true
        defer { isPreparingInstallation = false }
        await waitForDevicePoll()
        guard !Task.isCancelled else { return }
        let expected = preflightInput
        await checkPlan()
        guard expected == preflightInput, preparationIsCurrent, preparation?.isPrepared == true else {
            notice = AppNotice(level: .warning, title: "安装前检查未通过",
                               message: preparation?.issues.first?.message ?? "来源或计划已变化，请检查待选文件后重试。")
            return
        }
        guard let review = await makeMTPInstallationReview() else {
            if notice == nil {
                notice = AppNotice(level: .warning, title: "暂时无法开始安装", message: "连接或文件条件发生变化；未发送任何文件，请查看连接指引后重试。")
            }
            return
        }
        startMTPInstallation(review)
    }

    func cancelInstallationReview() {
        installationReview = nil
        reviewedPlan = nil
    }

    var queueValidationIssues: [String] {
        var issues: [String] = []
        let selectedItems = plan.filter { !$0.includedContents.isEmpty }
        if !InstallQueueRules.targetsAreConsistent(selectedItems.map { $0.target.rawValue }) {
            issues.append("所选文件的计划目标不一致；请统一为 SD 卡或机身存储。")
        }
        for item in plan where needsUpdateChoice(item) {
            issues.append("「\(item.title)」的更新版本或身份不明确；请展开文件清单选择一个更新，或明确本次不安装更新。")
        }
        for item in plan {
            let included = item.includedContents.map { ($0.kind, $0.format) }
            let bases = item.contents.filter { $0.kind == .base }
            let includedBases = item.includedContents.filter { $0.kind == .base }
            if BaseSelection.integratedPackageHasCompany(included) {
                issues.append("「\(item.title)」选择了 XCI 整合包，请取消其他本体、更新和 DLC。整合包单独安装。")
            } else if bases.count > 1, includedBases.count != 1 {
                issues.append("「\(item.title)」有多个本体。请只保留一个；XCI 是整合包，NSP 是单独的本体。")
            }
        }
        for item in selectedItems where UpdateSelection.hasConflict(
            updateIDs: Set(item.contents.filter { $0.kind == .update }.map(\.id)),
            selectedIDs: Set(item.includedContents.map(\.id))) {
            issues.append("「\(item.title)」选择了多个更新补丁；请只保留一个。")
        }
        return issues
    }

    var canReviewMTPInstallation: Bool {
        !automaticReadBlocked && !isInstalling && !isVerifyingInstall && !isReviewingInstall && !isReadingInventory && !isDiscovering && !isScanning &&
        !isCheckingPlan && !wifiBlocksUSB && preparationIsCurrent && preparation?.isPrepared == true && queueValidationIssues.isEmpty
    }

    private func makeMTPInstallationReview() async -> SphairaBatchReview? {
        guard canReviewMTPInstallation else { return nil }
        let input = preflightInput
        var candidates: [(String, String, URL, URL, UInt64)] = []
        for item in input.items {
            let title = plan.first(where: { $0.id == item.id })?.title ?? item.id
            for entry in item.entries where entry.included {
                guard let url = entry.sourceURL, entry.expectedBytes > 0,
                      let root = snapshot.sources.filter({ $0.availability == .online && isUnder(url, source: $0) })
                        .max(by: { $0.url.path.count < $1.url.path.count })?.url else { return nil }
                candidates.append((title, item.intendedTarget, url, root, UInt64(entry.expectedBytes)))
            }
        }
        guard !candidates.isEmpty else { return nil }
        isReviewingInstall = true
        defer { isReviewingInstall = false }
        do {
            let sources = candidates
            let items = try await Task.detached(priority: .utility) {
                try sources.map { title, target, url, root, size in
                    SphairaBatchItem(gameTitle: title, request: try SphairaInstallRequest.review(
                        sourceURL: url, allowedRoot: root, expectedBytes: size, intendedTarget: target))
                }
            }.value
            guard input == preflightInput, !isInstalling, !isReadingInventory, !isDiscovering,
                  !isScanning, !wifiBlocksUSB, preparationIsCurrent, queueValidationIssues.isEmpty else { return nil }
            reviewedPlan = input
            return SphairaBatchReview(items: items)
        } catch {
            notice = AppNotice(level: .warning, title: "无法开始安装", message: "源文件元数据或路径已变化，请重新扫描并检查计划。未连接设备。")
            return nil
        }
    }

    private func startMTPInstallation(_ review: SphairaBatchReview) {
        if wifiBlocksUSB {
            notice = wifiBlocksUSBNotice
            return
        }
        guard !automaticReadBlocked, !isVerifyingInstall, !isInstalling, !isReadingInventory, !isDiscovering, !isScanning, !wifiBlocksUSB,
              let signature = mtpCandidateSignature, !review.items.isEmpty, reviewedPlan == preflightInput,
              preparationIsCurrent, queueValidationIssues.isEmpty else {
            reviewedPlan = nil
            return
        }
        reviewedPlan = nil
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "io.ganeshrvel.openmtp" }) {
            notice = AppNotice(level: .warning, title: "请先完整退出 OpenMTP", message: "未启动传输。请退出其他 MTP 客户端后再点击开始安装。")
            return
        }
        isInstalling = true
        isVerifyingInstall = false
        installListConfirmed = false
        completedInstallGameIDs = []
        verificationDetail = nil
        installStatuses = []
        inventory = cachedInventory
        inventorySessionSignature = nil
        notice = nil
        let installer = mtpInstaller
        installTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isInstalling = false; self.installTask = nil }
            await SphairaBatchInstaller.run(review.items, send: { request, progress in
                try await installer.install(request, progress: progress)
            }, observe: { [weak self] event in
                await MainActor.run {
                    guard let self, self.isInstalling else { return }
                    switch event {
                    case .statuses(let statuses): self.installStatuses = statuses
                    case .progress(let id, let bytes, let phase):
                        guard let index = self.installStatuses.firstIndex(where: { $0.item.id == id }),
                              case .sending = self.installStatuses[index].state else { return }
                        self.installStatuses[index].bytesSubmitted = bytes
                        self.installStatuses[index].phase = phase
                    }
                }
            })
            if await installer.hasUnverifiedWorker { self.automaticReadBlocked = true }
            let stopped = self.installStatuses.contains { if case .stopped = $0.state { true } else { false } }
            let incomplete = self.installStatuses.contains { if case .waiting = $0.state { true } else { false } }
            let transferred = !self.installStatuses.isEmpty && self.installStatuses.allSatisfy { if case .transferred = $0.state { true } else { false } }
            if transferred && !stopped && !incomplete {
                self.isInstalling = false
                self.isVerifyingInstall = true
                self.showVerifyingNotice()
                let confirmed = await self.confirmTransferredInstall(expectedSignature: signature)
                await self.finishInstallVerification(confirmed: confirmed)
            } else {
                self.installListConfirmed = false
                self.notice = AppNotice(level: .warning,
                    title: "队列已停止",
                    message: "后续文件未发送。请查看设备上的安装结果；已经发送完成的文件不会自动重传。")
            }
        }
    }

    func cancelMTPInstallation() {
        if isVerifyingInstall {
            // A user stop must not immediately trigger the background read again.
            automaticAttempts = 2
            lastAutomaticAttempt = Date()
        }
        installTask?.cancel()
    }

    /// Only the USB registry entry used for the send may confirm this batch.
    /// Each helper fully exits before another session opens; no transport fallback.
    private func confirmTransferredInstall(expectedSignature: String) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var attempts = 0
        var retryDelay: Duration = .seconds(2)
        while !Task.isCancelled, !automaticReadBlocked, attempts < 4, ContinuousClock.now < deadline {
            showVerifyingNotice()
            await waitForDevicePoll()
            guard !Task.isCancelled else { break }
            deviceDiscovery = await discoverDevice()
            guard mtpCandidateSignature == expectedSignature else {
                inventory = cachedInventory
                inventorySessionSignature = nil
                verificationDetail = "USB 已断开或候选设备已变化；停止核对，请重新连接后手动读取清单。"
                return false
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            let seconds = min(30, max(1, Int(remaining.components.seconds)))
            attempts += 1
            let readSucceeded = await readInventory(forVerification: true, timeoutSeconds: seconds)
            if readSucceeded, transferredQueueShowsInstalled() { return true }
            if attempts == 4 {
                if readSucceeded, inventory?.isComplete == true {
                    verificationDetail = "所选内容尚未出现在 Games 清单。sphaira 可能缓存清单；若设备已完成安装，请退出并重新打开 sphaira，再点击重新检测核对。待选项已保留，不会自动重传。"
                }
                break
            }
            if Task.isCancelled || automaticReadBlocked { break }
            let pause = ContinuousClock.now.duration(to: deadline)
            if pause <= .zero { break }
            do { try await Task.sleep(for: min(retryDelay, pause)) }
            catch { break }
            retryDelay *= 2
        }
        if Task.isCancelled { verificationDetail = "已停止核对；已发送的文件不会自动重传。" }
        return false
    }

    private func showVerifyingNotice() {
        notice = AppNotice(
            level: .info,
            title: "正在核对已安装清单",
            message: verificationDetail ?? "文件已经发送。正在通过 libusb 读取 Games 清单并核对所选内容和版本；核对成功后才会移出待选区。"
        )
    }

    private func finishInstallVerification(confirmed: Bool) async {
        // Keep the plan locked until the success indication has had time to appear.
        installListConfirmed = confirmed
        if confirmed {
            completedInstallGameIDs = Set(plan.filter { !$0.includedContents.isEmpty }.map(\.gameID))
            NSSound(named: "Hero")?.play()
            notice = AppNotice(level: .info, title: "游戏安装成功", message: "已通过设备清单核对所选内容和版本，正在移出待选区。")
            // Cancellation after confirmation must not undo the evidence or leave a
            // completed item staged for an accidental second send.
            try? await Task.sleep(for: .milliseconds(600))
            plan.removeAll { completedInstallGameIDs.contains($0.gameID) }
            selectedGameIDs.subtract(completedInstallGameIDs)
            omittedUpdates = omittedUpdates.filter { id, _ in plan.contains { $0.id == id } }
            preparation = nil
            reviewedPlan = nil
            planSaveTask?.cancel()
            do {
                try await planStore.savePlan(plan)
                notice = AppNotice(level: .info, title: "游戏安装成功", message: "已核对所选内容和版本，并移出安装待选区。包身份仍按现有证据显示。")
            } catch {
                notice = AppNotice(level: .warning, title: "游戏已安装，待选区保存失败",
                                   message: "本次已移出待选区，但磁盘计划未能更新：\(error.localizedDescription)",
                                   action: .savePlan, actionLabel: "重试保存")
            }
        } else {
            notice = AppNotice(level: .warning, title: "传输完成，安装尚未确认",
                               message: verificationDetail ?? "Games 清单中的所选内容或版本尚未全部确认；待选项已保留，不会自动重传。",
                               action: .refreshDevices, actionLabel: "重新检测并核对")
        }
        isVerifyingInstall = false
    }

    /// Fresh current-session inventory only. A transfer receipt is not install success.
    private func transferredQueueShowsInstalled() -> Bool {
        guard inventoryIsCurrentSession, inventory?.isComplete == true, !installStatuses.isEmpty,
              installStatuses.allSatisfy({ if case .transferred = $0.state { true } else { false } }) else { return false }
        let relevant = plan.filter { !$0.includedContents.isEmpty }
        let selected = relevant.flatMap(\.includedContents)
        guard !selected.isEmpty, selected.count == installStatuses.count else { return false }
        // File names alone are not a durable identity. Match this batch's reviewed
        // source path, byte count and target before consulting fresh device records.
        return relevant.allSatisfy { item in
            guard let game = games.first(where: { $0.id == item.gameID }) else { return false }
            return item.includedContents.allSatisfy { content in
                guard content.byteCount > 0, let local = game.contents.first(where: { $0.id == content.id }),
                      installStatuses.contains(where: { status in
                          let request = status.item.request
                          return request.sourceURL == local.fileURL && request.byteCount == UInt64(content.byteCount)
                              && request.intendedTarget == item.target.rawValue
                      }) else { return false }
                return assessment(for: local, in: game).state == .installed
            }
        }
    }

    func openMTPInstallationRecords() {
        let url = appDirectory.appendingPathComponent("MTPInstallAttempts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

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
        guard !installationPlanLocked else { return }
        guard !game.contents.isEmpty else {
            notice = AppNotice(level: .info, title: "没有可加入的本地内容", message: "该条目没有可用于安装计划的文件。")
            return
        }
        // A repeat click must preserve explicit file/target choices and order.
        guard !isInPlan(game.id) else { return }
        plan.append(PlanItem(game: game))
        if persist { schedulePlanSave() }
    }

    func addSelectedToQueue() {
        for game in selectedGames { addToQueue(game, persist: false) }
        schedulePlanSave()
    }

    func updatePlanTarget(_ id: String, target: InstallTarget) {
        guard !installationPlanLocked else { return }
        guard let index = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[index].target = target
        schedulePlanSave()
    }

    func setPlanContentIncluded(_ itemID: String, contentID: String, included: Bool) {
        guard !installationPlanLocked else { return }
        guard let itemIndex = plan.firstIndex(where: { $0.id == itemID }),
              let contentIndex = plan[itemIndex].contents.firstIndex(where: { $0.id == contentID }) else { return }
        let contents = plan[itemIndex].contents
        let selected = UpdateSelection.applying(id: contents[contentIndex].id, included: included,
            updateIDs: Set(contents.filter { $0.kind == .update }.map(\.id)),
            selectedIDs: Set(contents.filter(\.included).map(\.id)))
        for index in plan[itemIndex].contents.indices {
            plan[itemIndex].contents[index].included = selected.contains(plan[itemIndex].contents[index].id)
        }
        schedulePlanSave()
    }

    func updatePlanNote(_ id: String, note: String) {
        guard !installationPlanLocked else { return }
        guard let index = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[index].note = note
        schedulePlanSave()
    }

    func movePlanItem(_ id: String, direction: Int) {
        guard !installationPlanLocked else { return }
        guard let index = plan.firstIndex(where: { $0.id == id }) else { return }
        let target = index + direction
        guard plan.indices.contains(target) else { return }
        plan.swapAt(index, target)
        schedulePlanSave()
    }

    func removePlanItem(_ id: String) {
        guard !installationPlanLocked else { return }
        plan.removeAll { $0.id == id }
        omittedUpdates[id] = nil
        schedulePlanSave()
    }

    func clearPlan() {
        guard !installationPlanLocked else { return }
        plan.removeAll()
        omittedUpdates.removeAll()
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
        let observation = inventory.map { absoluteTime($0.observedAt) } ?? "未知"
        let match: String
        if inventory == nil {
            match = "本地匹配：未知"
        } else if inventoryIsCurrentSession {
            match = "本地匹配：\(locallyMatchedGameCount) 款"
        } else {
            match = "本地匹配：非当前会话，不统计"
        }
        let lines = [
            "SwitchShelf 诊断摘要",
            "生成时间：\(absoluteTime(.now))",
            "游戏：\(games.count)；本地内容：\(totalContentCount)；来源：\(sourceCount)（在线 \(onlineSourceCount)）",
            "最后扫描：\(absoluteTime(snapshot.scannedAt))",
            "安装计划：\(plan.count) 项，\(formatByteCount(planTotalBytes))",
            "设备：\(device)",
            deviceSessionOverview.summaryLines(observationTime: observation).joined(separator: "\n"),
            match,
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
            Task { await detectAndRead() }
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

    // MARK: - DBI FTP, separate from USB

    func connectWiFi() async {
        guard !isWiFiBusy else { return }
        if isDiscovering || isReadingInventory || isInstalling {
            notice = AppNotice(
                level: .warning,
                title: "USB 会话还在进行",
                message: "请等 USB 检测、清单读取或安装结束后再连接无线 FTP。两条会话不能同时进行。",
                action: nil,
                actionLabel: nil
            )
            return
        }
        switch WiFiFTPEndpointParser.parse(host: wifiHost, portText: wifiPort) {
        case .rejected(let rejected):
            wifi = rejected
            noteRememberedHost(from: rejected)
        case .ready(let host, let port):
            isWiFiBusy = true
            wifi = .connecting(host: host, port: port)
            wifi = await wifiClient.connect(host: host, port: port)
            noteRememberedHost(from: wifi)
            isWiFiBusy = false
        }
    }

    private func noteRememberedHost(from snapshot: WiFiFTPSnapshot) {
        rememberedWiFiHost = WiFiFTPRememberedHost.recordFirstConnection(
            host: snapshot.host,
            phase: snapshot.phase,
            defaults: UserDefaults.standard
        )
    }

    func disconnectWiFi() async {
        guard isWiFiBusy || wifi.phase == .connected || wifi.phase == .connecting else {
            wifi = await wifiClient.disconnect()
            return
        }
        isWiFiBusy = true
        wifi = await wifiClient.disconnect()
        isWiFiBusy = false
    }

    private var wifiBlocksUSBNotice: AppNotice {
        AppNotice(
            level: .warning,
            title: "无线 FTP 仍占用这条连接",
            message: "已跳过 USB 检测、清单读取和安装，避免与无线会话并发。请先在「无线连接」断开。",
            action: nil,
            actionLabel: nil
        )
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
