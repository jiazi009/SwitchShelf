import Darwin
import Foundation

/// Inputs are derived from the current library snapshot, never from a plan ID interpreted as a path.
public struct BackendPreflightEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let expectedBytes: Int64
    public let included: Bool
    public let sourceURL: URL?
    public let sourceAvailable: Bool
    public let snapshotBytes: Int64?

    public init(id: String, name: String, expectedBytes: Int64, included: Bool, sourceURL: URL?, sourceAvailable: Bool, snapshotBytes: Int64? = nil) {
        self.id = id
        self.name = name
        self.expectedBytes = expectedBytes
        self.included = included
        self.sourceURL = sourceURL
        self.sourceAvailable = sourceAvailable
        self.snapshotBytes = snapshotBytes
    }
}

/// Ordered plan input; destination is recorded only as local intent, not sent by the host protocol.
public struct BackendPreflightItem: Equatable, Sendable {
    public let id: String
    public let intendedTarget: String
    public let entries: [BackendPreflightEntry]

    public init(id: String, intendedTarget: String, entries: [BackendPreflightEntry]) {
        self.id = id
        self.intendedTarget = intendedTarget
        self.entries = entries
    }
}

public struct BackendPreflightInput: Equatable, Sendable {
    public let items: [BackendPreflightItem]
    public init(items: [BackendPreflightItem]) { self.items = items }
}

public struct BackendPreflightIssue: Equatable, Sendable {
    public let fileID: String?
    public let message: String
    public init(fileID: String?, message: String) {
        self.fileID = fileID
        self.message = message
    }
}

/// Metadata-only result. Offers are descriptive and must never be treated as transfer authorization.
public struct BackendPreflightResult: Sendable {
    public let input: BackendPreflightInput
    public let offers: [BackendFileOffer]
    public let issues: [BackendPreflightIssue]
    public let checkedAt: Date

    public var isPrepared: Bool { issues.isEmpty && !offers.isEmpty }
    public func isCurrent(for input: BackendPreflightInput) -> Bool { self.input == input }
}

public enum BackendPreflight {
    /// Synchronous metadata inspection. Call from a background actor, never on MainActor.
    public static func check(_ input: BackendPreflightInput) -> BackendPreflightResult {
        var offers: [BackendFileOffer] = []
        var issues: [BackendPreflightIssue] = []
        var names = Set<String>()
        var ids = Set<String>()
        var listBytes = 0
        let entries = input.items.flatMap(\.entries).filter(\.included)
        if entries.isEmpty {
            issues.append(.init(fileID: nil, message: "计划未选择任何内容文件。"))
        }
        for entry in entries {
            let id = entry.id
            if !ids.insert(id).inserted {
                issues.append(.init(fileID: id, message: "内容 ID 重复，无法唯一提供文件。"))
                continue
            }
            let bytes = Array(entry.name.utf8)
            let extensionName = (entry.name as NSString).pathExtension.lowercased()
            if bytes.isEmpty || bytes.count > 255 || entry.name == "." || entry.name == ".." ||
                entry.name.contains("/") || entry.name.contains("\\") ||
                entry.name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) ||
                !["nsp", "xci", "nsz", "xcz"].contains(extensionName) {
                issues.append(.init(fileID: id, message: "文件名无法安全表示为 Backend 包文件名（需 1–255 UTF-8 字节、支持的扩展名且无路径/控制字符）。"))
                continue
            }
            if !names.insert(entry.name).inserted {
                issues.append(.init(fileID: id, message: "Backend 文件名重复，设备无法区分同名文件。"))
                continue
            }
            guard let url = entry.sourceURL, url.isFileURL else {
                issues.append(.init(fileID: id, message: "当前游戏库没有此内容 ID 的本地源文件映射。"))
                continue
            }
            guard url.lastPathComponent == entry.name else {
                issues.append(.init(fileID: id, message: "计划文件名与当前来源不一致；请更新计划。"))
                continue
            }
            guard entry.sourceAvailable else {
                issues.append(.init(fileID: id, message: "来源标记为离线或状态未知，请先重新扫描。"))
                continue
            }
            guard entry.snapshotBytes == nil || entry.snapshotBytes == entry.expectedBytes else {
                issues.append(.init(fileID: id, message: "游戏库记录的大小与计划不同；请更新计划。"))
                continue
            }
            guard entry.expectedBytes >= 0 else {
                issues.append(.init(fileID: id, message: "计划文件大小无效。"))
                continue
            }
            var info = stat()
            if lstat(url.path, &info) != 0 {
                issues.append(.init(fileID: id, message: "无法读取源文件元数据：\(String(cString: strerror(errno)))。"))
                continue
            }
            if (info.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) {
                issues.append(.init(fileID: id, message: "源文件不是普通文件（符号链接也不允许）。"))
                continue
            }
            if access(url.path, R_OK) != 0 || info.st_mode & 0o444 == 0 {
                issues.append(.init(fileID: id, message: "源文件不可读。"))
                continue
            }
            if info.st_size != entry.expectedBytes {
                issues.append(.init(fileID: id, message: "源文件大小已变化；请重新扫描并更新计划。"))
                continue
            }
            // Pinned dbibackend list is UTF-8 basename + LF per offer, final LF included.
            // The protocol's bounded default list payload is 65,536 bytes.
            let nextBytes = bytes.count + 1
            if listBytes > 65_536 - nextBytes {
                issues.append(.init(fileID: id, message: "Backend 文件清单超过 65,536 字节上限。"))
                continue
            }
            listBytes += nextBytes
            offers.append(.init(id: id, name: entry.name, byteCount: UInt64(info.st_size)))
        }
        return .init(input: input, offers: offers, issues: issues, checkedAt: .now)
    }
}

/// Serializes blocking filesystem metadata operations away from the UI actor.
public actor BackendPreflightService {
    public init() {}
    public func check(_ input: BackendPreflightInput) -> BackendPreflightResult {
        BackendPreflight.check(input)
    }
}
