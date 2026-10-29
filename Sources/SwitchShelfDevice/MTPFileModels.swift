import Foundation

/// A logical path, re-resolved inside each newly opened MTP session. USB object
/// and storage handles never leave the worker or survive an operation.
public struct MTPFileLocation: Codable, Sendable, Equatable, Hashable {
    public var storageName: String
    public var components: [String]
    public init(storageName: String, components: [String] = []) {
        self.storageName = storageName; self.components = components
    }
    public var displayPath: String { ([storageName] + components).joined(separator: "/") }
}

public struct MTPFileStorage: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var capacityBytes: UInt64?
    public var freeBytes: UInt64?
    public var canUpload: Bool
    public var isReadOnly: Bool
    public var role: String
    public var id: String { name }
    public init(name: String, capacityBytes: UInt64? = nil, freeBytes: UInt64? = nil,
                canUpload: Bool = false, isReadOnly: Bool = true, role: String = "只读设备入口") {
        self.name = name; self.capacityBytes = capacityBytes; self.freeBytes = freeBytes
        self.canUpload = canUpload; self.isReadOnly = isReadOnly; self.role = role
    }
}

public struct MTPFileEntry: Codable, Sendable, Equatable, Identifiable {
    public var location: MTPFileLocation
    public var name: String
    public var isDirectory: Bool
    public var byteCount: UInt64?
    /// Device-reported MTP timestamp text; unknown is nil, never a guessed date.
    public var modifiedDate: String?
    public var id: String { location.displayPath + "/" + name }
    public init(location: MTPFileLocation, name: String, isDirectory: Bool,
                byteCount: UInt64? = nil, modifiedDate: String? = nil) {
        self.location = location; self.name = name; self.isDirectory = isDirectory
        self.byteCount = byteCount; self.modifiedDate = modifiedDate
    }
    public var directoryLocation: MTPFileLocation {
        MTPFileLocation(storageName: location.storageName, components: location.components + [name])
    }
}

public struct MTPFileListing: Codable, Sendable, Equatable {
    public var location: MTPFileLocation
    public var storage: MTPFileStorage
    public var entries: [MTPFileEntry]
    public init(location: MTPFileLocation, storage: MTPFileStorage, entries: [MTPFileEntry]) {
        self.location = location; self.storage = storage; self.entries = entries
    }
}

public enum MTPFileOperation: String, Codable, Sendable { case storages, list, download, upload, albumIndex }
public enum MTPFileOutcome: String, Codable, Sendable { case completed, failed, cancelled, deviceStateUnknown }

public struct MTPFileRequest: Codable, Sendable, Identifiable {
    public let id: String
    public let operation: MTPFileOperation
    public let location: MTPFileLocation?
    public let entry: MTPFileEntry?
    public let localURL: URL?
    public let uploadSource: MTPFileUploadSource?
    public init(id: String = UUID().uuidString, operation: MTPFileOperation,
                location: MTPFileLocation? = nil, entry: MTPFileEntry? = nil,
                localURL: URL? = nil, uploadSource: MTPFileUploadSource? = nil) {
        self.id = id; self.operation = operation; self.location = location
        self.entry = entry; self.localURL = localURL; self.uploadSource = uploadSource
    }
    public static func storages() -> Self { Self(operation: .storages) }
    /// Metadata only. Finds screenshot files under recognized album roots; does not download or modify the device.
    public static func albumIndex() -> Self { Self(operation: .albumIndex) }
    public static func list(location: MTPFileLocation) -> Self { Self(operation: .list, location: location) }
    public static func download(entry: MTPFileEntry, to destination: URL) -> Self {
        Self(operation: .download, location: entry.location, entry: entry, localURL: destination)
    }
    /// Metadata-only preparation. Must run off MainActor; does not open USB.
    public static func upload(sourceURL: URL, to location: MTPFileLocation) throws -> Self {
        Self(operation: .upload, location: location, localURL: sourceURL,
             uploadSource: try MTPFileUploadSource.review(sourceURL))
    }
}

public struct MTPFileProgress: Codable, Sendable, Equatable {
    public var requestID: String
    public var phase: String
    public var bytesTransferred: UInt64
    public var totalBytes: UInt64?
    public var updatedAt: Date
    public init(requestID: String, phase: String, bytesTransferred: UInt64,
                totalBytes: UInt64? = nil, updatedAt: Date = .now) {
        self.requestID = requestID; self.phase = phase; self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes; self.updatedAt = updatedAt
    }
}

public struct MTPFileResult: Codable, Sendable {
    public var requestID: String
    public var operation: MTPFileOperation
    public var outcome: MTPFileOutcome
    public var storages: [MTPFileStorage]
    public var listing: MTPFileListing?
    /// Screenshot files found by `albumIndex`. Nil for every other operation.
    public var albumEntries: [MTPFileEntry]?
    /// True when `albumIndex` stopped at a depth, count or object limit. Nil for other operations.
    public var albumTruncated: Bool?
    public var transferredBytes: UInt64
    public var releaseVerified: Bool
    public var message: String
    public init(requestID: String, operation: MTPFileOperation, outcome: MTPFileOutcome,
                storages: [MTPFileStorage] = [], listing: MTPFileListing? = nil,
                albumEntries: [MTPFileEntry]? = nil, albumTruncated: Bool? = nil,
                transferredBytes: UInt64 = 0, releaseVerified: Bool = true, message: String) {
        self.requestID = requestID; self.operation = operation; self.outcome = outcome
        self.storages = storages; self.listing = listing
        self.albumEntries = albumEntries; self.albumTruncated = albumTruncated
        self.transferredBytes = transferredBytes
        self.releaseVerified = releaseVerified; self.message = message
    }
}

public enum MTPFileError: Error, LocalizedError, Sendable, Equatable {
    case invalidRequest, invalidPath, ambiguousPath, changedEntry, destinationExists
    case uploadNotAllowed, invalidMetadata, invalidResponse, resourceLimit
    case localAccess, sourceChanged, incompleteTransfer, response(UInt16)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: "文件操作请求无效；未开始传输。"
        case .invalidPath: "设备路径无效或文件名无法安全传输。"
        case .ambiguousPath: "设备入口或文件名不唯一，无法确定目标；请重新浏览。"
        case .changedEntry: "设备上的文件或目录已变化；请刷新后重新选择。"
        case .destinationExists: "目标中已有同名文件；未覆盖。请选择其他文件名。"
        case .uploadNotAllowed: "普通上传仅支持可写的 microSD card 目录；安装包请使用游戏安装流程。"
        case .invalidMetadata: "设备返回的文件元数据无效；无法可靠显示或传输。"
        case .invalidResponse: "设备 MTP 响应无效；本次操作未确认完成。"
        case .resourceLimit: "设备目录或数据超过本次操作的安全限制。"
        case .localAccess: "无法安全访问本机文件或目录；不会写入游戏来源目录。"
        case .sourceChanged: "本机源文件在准备后发生变化；已停止上传。"
        case .incompleteTransfer: "传输字节数与设备元数据不一致；未完成文件保存。"
        case .response(let code): String(format: "设备拒绝文件操作（PTP 0x%04X）；请检查模式与连接。", Int(code))
        }
    }
}
