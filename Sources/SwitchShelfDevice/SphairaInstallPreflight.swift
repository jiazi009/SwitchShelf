import Darwin
import Foundation

/// Derived from the current library mapping, never from an opaque plan ID as a path.
public struct SphairaPreflightEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let expectedBytes: Int64
    public let included: Bool
    public let sourceURL: URL?
    public let sourceAvailable: Bool
    public let snapshotBytes: Int64?

    public init(id: String, name: String, expectedBytes: Int64, included: Bool,
                sourceURL: URL?, sourceAvailable: Bool, snapshotBytes: Int64? = nil) {
        self.id = id; self.name = name; self.expectedBytes = expectedBytes
        self.included = included; self.sourceURL = sourceURL
        self.sourceAvailable = sourceAvailable; self.snapshotBytes = snapshotBytes
    }
}

public struct SphairaPreflightItem: Equatable, Sendable {
    public let id: String
    /// Local intent only. The selected storage inside sphaira determines the destination.
    public let intendedTarget: String
    public let entries: [SphairaPreflightEntry]

    public init(id: String, intendedTarget: String, entries: [SphairaPreflightEntry]) {
        self.id = id; self.intendedTarget = intendedTarget; self.entries = entries
    }
}

public struct SphairaPreflightInput: Equatable, Sendable {
    public let items: [SphairaPreflightItem]
    public init(items: [SphairaPreflightItem]) { self.items = items }
}

public struct SphairaPreflightIssue: Equatable, Sendable {
    public let fileID: String?
    public let message: String
}

public struct SphairaFileOffer: Equatable, Sendable {
    public let id: String
    public let name: String
    public let byteCount: UInt64
}

/// Metadata only: neither a transfer authorization nor evidence of package identity/device readiness.
public struct SphairaPreflightResult: Sendable {
    public let input: SphairaPreflightInput
    public let offers: [SphairaFileOffer]
    public let issues: [SphairaPreflightIssue]
    public let checkedAt: Date
    public var isPrepared: Bool { issues.isEmpty && !offers.isEmpty }
    public func isCurrent(for input: SphairaPreflightInput) -> Bool { self.input == input }
}

enum SphairaPackageName {
    static func isValid(_ name: String) -> Bool {
        // PTP strings have a UInt8 UTF-16 unit count, including their NUL terminator.
        // A UTF-8 bound also keeps the device-side filesystem component bounded.
        !name.isEmpty && name.utf16.count <= 254 && name.utf8.count <= 255 &&
        name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
        !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
        }) &&
        ["nsp", "xci", "nsz", "xcz", "msp"].contains((name as NSString).pathExtension.lowercased())
    }

    static func collisionKey(_ name: String) -> String {
        // More conservative than sphaira's ASCII-only virtual filesystem folding.
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

public enum SphairaInstallPreflight {
    /// No file-content reads and no USB access. Run off MainActor; SMB metadata can block.
    public static func check(_ input: SphairaPreflightInput) -> SphairaPreflightResult {
        var offers: [SphairaFileOffer] = []
        var issues: [SphairaPreflightIssue] = []
        var ids = Set<String>()
        var names = Set<String>()
        let entries = input.items.flatMap(\.entries).filter(\.included)
        if entries.isEmpty { issues.append(.init(fileID: nil, message: "计划未选择任何内容文件。")) }
        for entry in entries {
            func issue(_ message: String) { issues.append(.init(fileID: entry.id, message: message)) }
            guard !entry.id.isEmpty, ids.insert(entry.id).inserted else {
                issue("内容 ID 重复或为空，无法唯一提供文件。"); continue
            }
            guard SphairaPackageName.isValid(entry.name) else {
                issue("文件名不符合 MTP／设备路径限制，或不是 NSP、XCI、NSZ、XCZ、MSP 包文件。"); continue
            }
            guard names.insert(SphairaPackageName.collisionKey(entry.name)).inserted else {
                issue("安装文件名重复（忽略大小写／Unicode 等价形式）；请拆分计划。"); continue
            }
            guard let url = entry.sourceURL, url.isFileURL,
                  !url.path.contains("\0"), url.lastPathComponent == entry.name else {
                issue("当前游戏库缺少一致的本地源文件映射；请更新计划。"); continue
            }
            guard entry.sourceAvailable else {
                issue("来源离线或状态未知，请先重新扫描。"); continue
            }
            guard entry.expectedBytes > 0,
                  entry.snapshotBytes == nil || entry.snapshotBytes == entry.expectedBytes else {
                issue("文件大小无效或计划与游戏库记录不同；请更新计划。"); continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                issue("无法读取源文件元数据，请检查来源连接与访问权限。"); continue
            }
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  let canonical = realpath(url.path, nil) else {
                issue("源文件必须是普通文件，路径不能包含符号链接。"); continue
            }
            let canonicalPath = String(cString: canonical)
            free(canonical)
            guard canonicalPath == url.path else {
                issue("源文件必须是普通文件，路径不能包含符号链接。"); continue
            }
            guard access(url.path, R_OK) == 0, info.st_mode & 0o444 != 0 else {
                issue("源文件不可读。"); continue
            }
            guard info.st_size == entry.expectedBytes else {
                issue("源文件大小已变化；请重新扫描并更新计划。"); continue
            }
            offers.append(.init(id: entry.id, name: entry.name, byteCount: UInt64(info.st_size)))
        }
        return .init(input: input, offers: offers, issues: issues, checkedAt: .now)
    }
}

public actor SphairaPreflightService {
    public init() {}
    public func check(_ input: SphairaPreflightInput) -> SphairaPreflightResult {
        SphairaInstallPreflight.check(input)
    }
}
