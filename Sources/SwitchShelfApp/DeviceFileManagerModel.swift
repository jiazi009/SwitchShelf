import AppKit
import Foundation
import Observation
import SwitchShelfDevice

/// Transient, session-scoped file browsing. Logical paths are re-resolved by an
/// isolated worker on every operation; no device handles are retained here.
@MainActor
@Observable
final class DeviceFileManagerModel {
    struct Row: Identifiable {
        let id: String
        let entry: MTPFileEntry
    }
    enum SortOrder: String, CaseIterable, Identifiable {
        case name, size, modified
        var id: String { rawValue }
        var label: String {
            switch self { case .name: "名称"; case .size: "大小"; case .modified: "修改时间" }
        }
    }

    private(set) var storages: [MTPFileStorage] = []
    private(set) var listing: MTPFileListing?
    private(set) var deviceSignature: String?
    private(set) var isBusy = false
    private(set) var hasUnverifiedWorker = false
    private(set) var progress: MTPFileProgress?
    private(set) var operationTitle = ""
    private(set) var backLocations: [MTPFileLocation] = []
    private(set) var message: String?
    private(set) var messageIsError = false
    var selectedEntryID: String?
    var searchText = ""
    var sortOrder: SortOrder = .name

    /// Root composition supplies only blockers from other USB/Wi-Fi operations.
    @ObservationIgnored var canStart: @MainActor () -> String? = { nil }
    @ObservationIgnored private let client: BoundedDeviceFileClient
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(client: BoundedDeviceFileClient = BoundedDeviceFileClient()) { self.client = client }

    var location: MTPFileLocation? { listing?.location }
    var currentStorage: MTPFileStorage? { listing?.storage }
    private var rows: [Row] {
        let entries = listing?.entries ?? []
        return entries.enumerated().map { index, entry in
            Row(id: "\(index):\(entry.id)", entry: entry)
        }
    }
    var selectedEntry: MTPFileEntry? { rows.first { $0.id == selectedEntryID }?.entry }
    private var selectedEntryIsAmbiguous: Bool {
        guard let entry = selectedEntry else { return false }
        return listing?.entries.filter { $0.id == entry.id }.count != 1
    }
    var blocker: String? {
        if hasUnverifiedWorker { return "文件辅助进程退出未确认，请重启应用并检查设备。" }
        guard deviceSignature != nil else { return "连接一台 Switch 并开启 MTP，随后读取设备存储。" }
        return canStart()
    }
    var canUpload: Bool { !isBusy && blocker == nil && currentStorage?.canUpload == true }
    var downloadIssue: String? {
        guard let entry = selectedEntry, !entry.isDirectory else { return nil }
        guard !selectedEntryIsAmbiguous else { return "设备报告了重复文件名，无法确定要下载的文件。" }
        guard let size = entry.byteCount else { return "设备未提供文件大小，暂时无法下载这个文件。" }
        guard size < UInt64(UInt32.max) - 12 else { return "单个传输文件需小于 4 GiB，请选择其他文件。" }
        return nil
    }
    var canDownload: Bool { !isBusy && blocker == nil && selectedEntry?.isDirectory == false && downloadIssue == nil }
    var canOpenSelection: Bool { !isBusy && blocker == nil && selectedEntry?.isDirectory == true && !selectedEntryIsAmbiguous }
    var canGoBack: Bool { !isBusy && blocker == nil && !backLocations.isEmpty }

    var visibleEntries: [MTPFileEntry] { visibleRows.map(\.entry) }
    var visibleRows: [Row] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { query.isEmpty || $0.entry.name.localizedStandardContains(query) }.sorted { leftRow, rightRow in
            let left = leftRow.entry, right = rightRow.entry
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            switch sortOrder {
            case .size:
                if left.byteCount != right.byteCount { return (left.byteCount ?? 0) > (right.byteCount ?? 0) }
            case .modified:
                if left.modifiedDate != right.modifiedDate { return (left.modifiedDate ?? "") > (right.modifiedDate ?? "") }
            case .name: break
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    func setDeviceSignature(_ value: String?) {
        guard value != deviceSignature else { return }
        generation += 1
        operationTask?.cancel()
        deviceSignature = value
        storages = []
        listing = nil
        pendingRefreshLocation = nil
        selectedEntryID = nil
        backLocations = []
        searchText = ""
        progress = nil
        messageIsError = false
        message = value == nil ? "设备连接已变化；重新连接后读取存储。" : nil
        // isBusy stays true until the old helper's exit has been verified.
    }

    func loadIfNeeded() {
        guard storages.isEmpty, !isBusy, blocker == nil else { return }
        refreshStorages()
    }

    func refreshStorages() {
        begin(title: "读取设备存储", prepare: { .storages() }) { [weak self] result in
            self?.storages = result.storages
            if let current = self?.listing?.location {
                let matches = result.storages.filter { $0.name == current.storageName }
                if matches.count == 1, let storage = matches.first {
                    self?.listing?.storage = storage
                } else {
                    self?.listing = nil
                    self?.selectedEntryID = nil
                    self?.backLocations = []
                }
            }
        }
    }

    func openStorage(_ storage: MTPFileStorage) {
        guard storages.filter({ $0.name == storage.name }).count == 1 else {
            showError("设备报告的存储名称不唯一，请重新读取存储后再试。")
            return
        }
        navigate(to: MTPFileLocation(storageName: storage.name))
    }

    func navigate(to location: MTPFileLocation, recordingHistory: Bool = true) {
        let previous = self.location
        begin(title: "读取文件夹", prepare: { .list(location: location) }) { [weak self] result in
            guard let listing = result.listing else { return }
            if recordingHistory, let previous, previous != listing.location {
                self?.backLocations.append(previous)
            } else if !recordingHistory {
                _ = self?.backLocations.popLast()
            }
            self?.listing = listing
            self?.selectedEntryID = nil
            self?.searchText = ""
            if let index = self?.storages.firstIndex(where: { $0.name == listing.storage.name }) {
                self?.storages[index] = listing.storage
            }
        }
    }

    func refresh() {
        if let location { navigate(to: location) } else { refreshStorages() }
    }

    func goUp() {
        guard var location, !location.components.isEmpty else { return }
        location.components.removeLast()
        navigate(to: location)
    }

    func goBack() {
        guard canGoBack, let location = backLocations.last else { return }
        navigate(to: location, recordingHistory: false)
    }

    func openSelected() {
        guard canOpenSelection, let selectedEntry else { return }
        navigate(to: selectedEntry.directoryLocation)
    }

    func open(_ entry: MTPFileEntry) {
        guard listing?.entries.filter({ $0.id == entry.id }).count == 1 else {
            showError("设备报告了重复文件名，无法确定要打开的文件夹。")
            return
        }
        selectedEntryID = rows.first(where: { $0.entry == entry })?.id
        guard entry.isDirectory else { return }
        navigate(to: entry.directoryLocation)
    }

    func dismissMessage() { message = nil }

    func cancel() {
        guard isBusy else { return }
        operationTitle = "正在停止…"
        operationTask?.cancel()
    }

    /// File pickers are reached only from explicit upload/download controls.
    func chooseUpload() {
        guard canUpload, let location else { return }
        let token = generation
        isBusy = true
        operationTitle = "选择上传文件"
        defer { if operationTask == nil { isBusy = false } }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "上传文件"
        panel.message = "上传到 \(location.displayPath)。已有同名文件时不会覆盖。"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        guard token == generation else { return }
        isBusy = false
        upload(sourceURL: source, to: location)
    }

    func upload(sourceURL: URL, to location: MTPFileLocation) {
        guard currentStorage?.canUpload == true, self.location == location else { return }
        guard !Self.isProtectedLocalURL(sourceURL),
              !["nsp", "xci", "nsz", "xcz", "msp"].contains(sourceURL.pathExtension.lowercased()) else {
            showError("游戏安装包请从游戏库的安装待选区发送；普通文件上传不读取游戏来源目录。")
            return
        }
        begin(title: "上传 \(sourceURL.lastPathComponent)", prepare: {
            try await Task.detached(priority: .utility) {
                try MTPFileRequest.upload(sourceURL: sourceURL, to: location)
            }.value
        }) { [weak self] _ in
            // Refresh is an explicit new operation after the transfer has released USB.
            self?.selectedEntryID = nil
            self?.message = "文件已上传。点击刷新重新读取目标目录。"
            self?.pendingRefreshLocation = location
        }
    }

    func chooseDownload() {
        guard canDownload, let entry = selectedEntry else { return }
        let token = generation
        isBusy = true
        operationTitle = "选择下载位置"
        defer { if operationTask == nil { isBusy = false } }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.prompt = "下载文件"
        panel.message = "选择本机保存位置；已有同名文件时不会覆盖。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard token == generation else { return }
        isBusy = false
        download(entry: entry, to: destination)
    }

    func download(entry: MTPFileEntry, to destination: URL) {
        guard !entry.isDirectory, listing?.entries.contains(entry) == true,
              listing?.entries.filter({ $0.id == entry.id }).count == 1 else { return }
        guard let size = entry.byteCount, size < UInt64(UInt32.max) - 12 else {
            showError("设备需提供可核对的文件大小，且单个传输文件需小于 4 GiB。")
            return
        }
        guard !Self.isProtectedLocalURL(destination) else {
            showError("请选择游戏来源目录以外的本机保存位置。")
            return
        }
        begin(title: "下载 \(entry.name)", prepare: { .download(entry: entry, to: destination) }) { _ in }
    }

    @ObservationIgnored private var pendingRefreshLocation: MTPFileLocation?

    func refreshCurrentFolder() {
        if let pendingRefreshLocation {
            self.pendingRefreshLocation = nil
            navigate(to: pendingRefreshLocation)
        } else { refresh() }
    }

    private func begin(title: String, prepare: @escaping @Sendable () async throws -> MTPFileRequest,
                       success: @escaping @MainActor (MTPFileResult) -> Void) {
        guard !isBusy else { return }
        if let blocker { showError(blocker); return }
        guard let signature = deviceSignature else { return }
        let token = generation
        isBusy = true
        operationTitle = title
        progress = nil
        message = nil
        messageIsError = false
        let client = client
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isBusy = false; self.operationTask = nil }
            do {
                let request = try await prepare()
                try Task.checkCancellation()
                guard token == self.generation else { return }
                let timeout: TimeInterval = request.operation == .upload || request.operation == .download ? 7_200 : 120
                let result = try await client.execute(request, expectedDeviceSignature: signature, timeoutSeconds: timeout) { [weak self] progress in
                    await self?.receive(progress, generation: token)
                }
                let fenced = await client.hasUnverifiedWorker
                self.hasUnverifiedWorker = self.hasUnverifiedWorker || fenced || !result.releaseVerified
                guard token == self.generation else { return }
                self.message = result.message
                self.messageIsError = result.outcome != .completed || !result.releaseVerified
                if result.outcome == .completed, result.releaseVerified { success(result) }
            } catch {
                let fenced = await client.hasUnverifiedWorker
                self.hasUnverifiedWorker = self.hasUnverifiedWorker || fenced
                guard token == self.generation else { return }
                self.showError(error is CancellationError ? "文件操作已停止；已传输内容以本次结果为准。" : error.localizedDescription)
            }
        }
    }

    private func receive(_ value: MTPFileProgress, generation: Int) {
        guard generation == self.generation else { return }
        progress = value
    }

    private func showError(_ text: String) { message = text; messageIsError = true }

    private static func isProtectedLocalURL(_ url: URL) -> Bool {
        let root = "/Volumes/switch 游戏包"
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }
}
