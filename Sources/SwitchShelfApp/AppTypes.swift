import Foundation
import SwitchShelfDomain

// MARK: - Navigation & filters

enum SidebarItem: Hashable {
    case all
    case recent
    case unidentified
    case queue
    case device
    case wifi
    case files
    case maintenance
    case source(String)

    var isLibraryPage: Bool {
        switch self {
        case .all, .recent, .unidentified, .source: true
        default: false
        }
    }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: String { rawValue }
    var label: String { self == .grid ? "网格" : "列表" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

enum ContentFilter: String, CaseIterable, Identifiable {
    case all, base, update, dlc, unknown
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部内容"
        case .base: "仅本体"
        case .update: "含更新"
        case .dlc: "含 DLC"
        case .unknown: "类型未知"
        }
    }

    func matches(_ game: Game) -> Bool {
        switch self {
        case .all: true
        default: game.contents.contains { content in
            switch self {
            case .base: content.kind == .base
            case .update: content.kind == .update
            case .dlc: content.kind == .dlc
            case .unknown: content.kind == .unknown
            case .all: true
            }
        }
        }
    }
}

struct InventoryDirectoryGroup: Identifiable, Equatable {
    var id: String
    var directoryName: String
    var records: [InstalledRecord]
    var localGameTitles: [String]
}

enum InstallFilter: String, CaseIterable, Identifiable {
    case all, installed, pending
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部安装状态"
        case .installed: "设备已安装"
        case .pending: "未确认已安装"
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case recent, title, size, contentCount
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "最近添加"
        case .title: "名称"
        case .size: "占用空间"
        case .contentCount: "内容数量"
        }
    }
}

// MARK: - Local installation plan

enum InstallTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case sd
    case nand
    var id: String { rawValue }
    var label: String { self == .sd ? "SD 卡" : "机身存储" }
    var symbol: String { self == .sd ? "sdcard" : "internaldrive" }
}

struct PlanContent: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: ContentKind
    var titleID: String?
    var version: String?
    var fileName: String
    var byteCount: Int64
    var format: PackageFormat
    var included: Bool

    init(content: LocalContent, included: Bool = true) {
        self.id = content.id
        self.kind = content.kind
        self.titleID = content.titleID
        self.version = content.displayVersion ?? formatVersion(content.rawVersion)
        self.fileName = content.fileURL.lastPathComponent
        self.byteCount = content.byteCount
        self.format = content.format
        self.included = included
    }
}

/// App-only defaults: candidate filename identities never become package proof.
enum InstallContentDefaults {
    static func latestUpdateID(in contents: [LocalContent]) -> String? {
        let updates = contents.filter { $0.kind == .update }
        guard !updates.isEmpty, updates.allSatisfy({ $0.rawVersion != nil }),
              let identity = InstallationAssessor.normalizedID(updates.first?.titleID),
              updates.allSatisfy({ InstallationAssessor.normalizedID($0.titleID) == identity }),
              let highest = updates.compactMap(\.rawVersion).max() else { return nil }
        let newest = updates.filter { $0.rawVersion == highest }
        return newest.count == 1 ? newest[0].id : nil
    }

    static func needsUpdateChoice(in contents: [LocalContent]) -> Bool {
        contents.contains { $0.kind == .update } && latestUpdateID(in: contents) == nil
    }
}

struct PlanItem: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var gameID: String
    var title: String
    var titleID: String?
    var contents: [PlanContent]
    var target: InstallTarget
    var note: String
    var addedAt: Date

    init(game: Game, target: InstallTarget = .sd, note: String = "", addedAt: Date = .now) {
        self.id = game.id
        self.gameID = game.id
        self.title = game.title
        self.titleID = game.contents.compactMap(\.titleID).first
        let selectedUpdateID = InstallContentDefaults.latestUpdateID(in: game.contents)
        let defaults = BaseSelection.defaultIncludedIDs(in: game.contents, updateID: selectedUpdateID)
        self.contents = game.contents
            .sorted { $0.kind.order == $1.kind.order ? $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent : $0.kind.order < $1.kind.order }
            .map { PlanContent(content: $0, included: defaults?.contains($0.id) == true) }
        self.target = target
        self.note = note
        self.addedAt = addedAt
    }

    var includedContents: [PlanContent] { contents.filter(\.included) }
    var byteCount: Int64 { includedContents.reduce(0) { $0 + $1.byteCount } }
}

// MARK: - Notices

struct AppNotice: Identifiable, Equatable {
    enum Level: Equatable { case info, warning, error }
    enum Action: Equatable {
        case scanAll
        case refreshDevices
        case readInventory
        case reloadCache
        case savePlan
        case refreshAvailability
        case openAppSupport
    }

    let id = UUID()
    var level: Level
    var title: String
    var message: String
    var action: Action?
    var actionLabel: String?

    init(level: Level, title: String, message: String, action: Action? = nil, actionLabel: String? = nil) {
        self.level = level
        self.title = title
        self.message = message
        self.action = action
        self.actionLabel = actionLabel
    }
}

// MARK: - Formatting

func formatByteCount(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "0 B" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatVersion(_ raw: UInt32?) -> String? {
    guard let raw else { return nil }
    return "\((raw >> 16) & 0xFF).\((raw >> 8) & 0xFF).\(raw & 0xFF)"
}

func normalizedTitleID(_ value: String?) -> String? {
    guard let value else { return nil }
    var text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if text.hasPrefix("0X") { text.removeFirst(2) }
    return text.isEmpty ? nil : text
}

func displayTitleID(_ value: String?) -> String {
    guard let value = normalizedTitleID(value) else { return "Title ID 未知" }
    return value
}

func relativeTime(_ date: Date?) -> String {
    guard let date else { return "尚未扫描" }
    let interval = Date.now.timeIntervalSince(date)
    if interval < 45 { return "刚刚" }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: .now)
}

func absoluteTime(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter.string(from: date)
}

func hexDeviceID(_ value: UInt16) -> String {
    String(format: "0x%04X", value)
}

func stableHue(_ text: String) -> Double {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return Double(hash % 360) / 360.0
}

// MARK: - Domain presentation

extension ContentKind {
    var order: Int {
        InstallQueueRules.order(self)
    }

    var label: String {
        switch self {
        case .base: "本体"
        case .update: "更新"
        case .dlc: "DLC"
        case .unknown: "未知内容"
        }
    }

    var symbol: String {
        switch self {
        case .base: "shippingbox"
        case .update: "arrow.down.circle"
        case .dlc: "puzzlepiece.extension"
        case .unknown: "questionmark.square.dashed"
        }
    }
}

extension IdentificationState {
    var label: String {
        switch self {
        case .verified: "已验证"
        case .matched: "已匹配"
        case .needsReview: "待识别"
        case .unidentified: "未识别"
        }
    }

    var isPending: Bool { self == .needsReview || self == .unidentified }
}

extension SourceAvailability {
    var label: String {
        switch self {
        case .online: "在线"
        case .offline: "离线"
        case .unknown: "未知"
        }
    }
}

extension InstallationState {
    var label: String {
        switch self {
        case .installed: "设备已安装"
        case .notInstalled: "未安装"
        case .partial: "部分安装"
        case .unknown: "待确认"
        }
    }

    var symbol: String {
        switch self {
        case .installed: "checkmark.seal.fill"
        case .notInstalled: "minus.circle"
        case .partial: "circle.lefthalf.filled"
        case .unknown: "questionmark.circle"
        }
    }
}

extension Game {
    var baseContents: [LocalContent] { contents.filter { $0.kind == .base } }

    var contentSummary: String {
        var parts: [String] = []
        if contents.contains(where: { $0.kind == .base }) { parts.append("本体") }
        if contents.contains(where: { $0.kind == .update }) { parts.append("更新") }
        let dlcCount = contents.filter { $0.kind == .dlc }.count
        if dlcCount == 1 { parts.append("DLC") } else if dlcCount > 1 { parts.append("\(dlcCount) 个 DLC") }
        if parts.isEmpty {
            let unknownCount = contents.filter { $0.kind == .unknown }.count
            return unknownCount > 0 ? "\(unknownCount) 个内容文件" : "无本地内容"
        }
        return parts.joined(separator: " · ")
    }

    var revealURL: URL? {
        baseContents.first?.fileURL ?? contents.first?.fileURL
    }

    var searchHaystack: String {
        ([title, originalTitle ?? ""] +
         contents.flatMap { [$0.fileURL.lastPathComponent, $0.titleID ?? "", $0.format.rawValue] })
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}
