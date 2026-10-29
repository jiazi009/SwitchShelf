import AppKit
import Darwin
import Foundation
import Observation
import SwitchShelfDevice

/// Session-scoped album screenshots. Listing is metadata; every preview and export
/// downloads through the existing single-file path and never changes the device.
@MainActor
@Observable
final class AlbumScreenshotModel {
    private(set) var screenshots: [MTPFileEntry] = []
    private(set) var truncated = false
    private(set) var deviceSignature: String?
    private(set) var isBusy = false
    private(set) var hasUnverifiedWorker = false
    private(set) var progress: MTPFileProgress?
    private(set) var operationTitle = ""
    private(set) var message: String?
    private(set) var messageIsError = false
    private(set) var previewImage: NSImage?
    private(set) var previewEntryID: String?
    var selectedEntryID: String?
    var searchText = ""

    @ObservationIgnored var canStart: @MainActor () -> String? = { nil }
    @ObservationIgnored private let client: BoundedDeviceFileClient
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var previewRoot: URL?

    init(client: BoundedDeviceFileClient = BoundedDeviceFileClient()) { self.client = client }

    var selectedEntry: MTPFileEntry? { screenshots.first { $0.id == selectedEntryID } }
    var blocker: String? {
        if hasUnverifiedWorker { return "文件辅助进程退出未确认，请重启应用并检查设备。" }
        guard deviceSignature != nil else { return "连接一台 Switch 并开启 MTP，随后读取相册。" }
        return canStart()
    }
    var visibleShots: [MTPFileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return screenshots }
        return screenshots.filter {
            $0.name.localizedStandardContains(query) || $0.location.displayPath.localizedStandardContains(query)
        }
    }
    var canRead: Bool { !isBusy && blocker == nil }
    var canDownloadSelection: Bool { canRead && selectedEntry?.byteCount != nil }
    var canDownloadVisible: Bool { canRead && !visibleShots.isEmpty && visibleShots.allSatisfy { $0.byteCount != nil } }

    func setDeviceSignature(_ value: String?) {
        guard value != deviceSignature else { return }
        generation += 1
        operationTask?.cancel()
        deviceSignature = value
        screenshots = []
        truncated = false
        selectedEntryID = nil
        searchText = ""
        progress = nil
        clearPreviewCache()
        messageIsError = false
        message = value == nil ? "设备连接已变化；重新连接后读取相册。" : nil
    }

    func loadIfNeeded() {
        guard screenshots.isEmpty, !isBusy, blocker == nil else { return }
        reload()
    }

    func reload() {
        begin(title: "读取相册截图", requests: { [.albumIndex()] }, timeout: 600) { [weak self] results in
            guard let result = results.first else { return }
            self?.screenshots = result.albumEntries ?? []
            self?.truncated = result.albumTruncated == true
            self?.selectedEntryID = nil
            self?.clearPreviewCache()
        }
    }

    func select(_ entry: MTPFileEntry) {
        guard !isBusy else { return }
        selectedEntryID = entry.id
        guard previewEntryID != entry.id || previewImage == nil else { return }
        guard let destination = previewDestination(for: entry) else { return }
        begin(title: "预览 \(entry.name)", requests: { [.download(entry: entry, to: destination)] }, timeout: 7_200) { [weak self] results in
            guard let self, results.first?.outcome == .completed else { return }
            guard let image = NSImage(contentsOf: destination) else {
                self.message = "截图已下载到缓存，但这份文件无法作为图片显示。"
                self.messageIsError = true
                self.previewImage = nil
                self.previewEntryID = entry.id
                return
            }
            self.previewImage = image
            self.previewEntryID = entry.id
            self.message = "预览已从设备下载。要保存到其他位置，使用下载。"
            self.messageIsError = false
        }
    }

    func downloadSelected() {
        guard canDownloadSelection, let entry = selectedEntry else { return }
        let token = generation
        isBusy = true
        operationTitle = "选择下载位置"
        defer { if operationTask == nil { isBusy = false } }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        panel.prompt = "下载截图"
        panel.message = "保存这张截图。已有同名文件时不会覆盖，设备上的文件不会被删除。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard token == generation else { return }
        isBusy = false
        let skipped = FileManager.default.fileExists(atPath: destination.path) ? 1 : 0
        export([(entry, destination)], title: "下载 \(entry.name)", skipped: skipped)
    }

    func downloadVisible() {
        guard canDownloadVisible else { return }
        let shots = visibleShots
        let token = generation
        isBusy = true
        operationTitle = "选择下载文件夹"
        defer { if operationTask == nil { isBusy = false } }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "下载到这里"
        panel.message = "当前列出的截图会按设备路径保存。已有同名文件不会覆盖，设备上的文件不会被删除。"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard token == generation else { return }
        isBusy = false
        let pairs = shots.map { ($0, localDestination(for: $0, root: folder)) }
        let skipped = pairs.filter { FileManager.default.fileExists(atPath: $0.1.path) }.count
        export(pairs, title: "下载相册截图", skipped: skipped)
    }

    func cancel() {
        guard isBusy else { return }
        operationTitle = "正在停止…"
        operationTask?.cancel()
    }

    func dismissMessage() { message = nil }

    private func export(_ pairs: [(MTPFileEntry, URL)], title: String, skipped: Int) {
        guard !pairs.isEmpty else { return }
        if pairs.contains(where: { Self.isProtectedLocalURL($0.1) }) {
            showError("请选择游戏来源目录以外的本机保存位置。")
            return
        }
        begin(title: title, requests: {
            var requests: [MTPFileRequest] = []
            for (entry, destination) in pairs {
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                requests.append(.download(entry: entry, to: destination))
            }
            return requests
        }, timeout: 7_200) { [weak self] results in
            self?.message = "已下载 \(results.count) 张到所选位置，跳过 \(skipped) 张已存在的文件。设备上的截图未删除或修改。"
            self?.messageIsError = false
        }
    }

    private func begin(title: String, requests: @escaping @Sendable () throws -> [MTPFileRequest], timeout: TimeInterval,
                       success: @escaping @MainActor ([MTPFileResult]) -> Void) {
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
            var completed: [MTPFileResult] = []
            do {
                let prepared = try await Task.detached(priority: .utility) { try requests() }.value
                for (index, request) in prepared.enumerated() {
                    try Task.checkCancellation()
                    guard token == self.generation else { return }
                    if prepared.count > 1 {
                        self.operationTitle = "\(title) \(index + 1)/\(prepared.count)"
                    }
                    let result = try await client.execute(request, expectedDeviceSignature: signature, timeoutSeconds: timeout) { [weak self] progress in
                        await self?.receive(progress, generation: token)
                    }
                    let fenced = await client.hasUnverifiedWorker
                    self.hasUnverifiedWorker = self.hasUnverifiedWorker || fenced || !result.releaseVerified
                    guard token == self.generation else { return }
                    guard result.outcome == .completed, result.releaseVerified else {
                        self.message = "已下载 \(completed.count) 张。\(result.message) 已保存的文件仍留在本机，设备文件未删除。"
                        self.messageIsError = true
                        return
                    }
                    completed.append(result)
                }
                guard token == self.generation else { return }
                if let summary = completed.last?.message, prepared.count <= 1 { self.message = summary }
                success(completed)
            } catch {
                let fenced = await client.hasUnverifiedWorker
                self.hasUnverifiedWorker = self.hasUnverifiedWorker || fenced
                guard token == self.generation else { return }
                let stopped = error is CancellationError
                let prefix = completed.isEmpty ? "" : "已下载 \(completed.count) 张。"
                self.showError(prefix + (stopped ? "下载已停止。已保存的文件仍留在本机，设备文件未删除。" : error.localizedDescription))
            }
        }
    }

    private func previewDestination(for entry: MTPFileEntry) -> URL? {
        do {
            let folder = try previewFolder()
            let ext = (entry.name as NSString).pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            return folder.appendingPathComponent(UUID().uuidString + suffix)
        } catch {
            showError(error.localizedDescription)
            return nil
        }
    }

    private func previewFolder() throws -> URL {
        if let previewRoot { return previewRoot }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwitchShelf", isDirectory: true)
            .appendingPathComponent("album-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let pointer = realpath(base.path, nil) else { throw MTPFileError.localAccess }
        defer { free(pointer) }
        let resolved = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
        guard resolved.lastPathComponent == "album-previews" else { throw MTPFileError.localAccess }
        previewRoot = resolved
        return resolved
    }

    private func clearPreviewCache() {
        previewImage = nil
        previewEntryID = nil
        if let previewRoot, previewRoot.lastPathComponent == "album-previews" {
            try? FileManager.default.removeItem(at: previewRoot)
        }
        previewRoot = nil
    }

    private func localDestination(for entry: MTPFileEntry, root: URL) -> URL {
        var url = root.appendingPathComponent(entry.location.storageName, isDirectory: true)
        for component in entry.location.components {
            url = url.appendingPathComponent(component, isDirectory: true)
        }
        return url.appendingPathComponent(entry.name)
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
