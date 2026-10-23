import Foundation

/// A file explicitly offered by the host. Requests select an offered name;
/// they never select an arbitrary filesystem path.
public struct BackendFileOffer: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let byteCount: UInt64

    public init(id: String, name: String, byteCount: UInt64) {
        self.id = id
        self.name = name
        self.byteCount = byteCount
    }
}

/// An explicitly opened Backend USB byte stream. Reads may be fragmented;
/// successful writes must account for the whole buffer. Implementations must
/// honor finite timeouts and must not reconnect or retry writes automatically.
public protocol BackendByteTransport: Sendable {
    func read(maximumLength: Int, timeoutMilliseconds: UInt32) async throws -> Data
    func write(_ data: Data, timeoutMilliseconds: UInt32) async throws
    func close() async throws
}

/// Implementations read only the requested range of an allowlisted file ID.
public protocol BackendFileReading: Sendable {
    func read(fileID: String, offset: UInt64, length: Int) async throws -> Data
}

/// Backend acknowledges file exchange, not installation on the console.
public enum BackendFileTransferPhase: String, Codable, Sendable {
    case notRequested
    case partiallyTransferred
    case transferredAwaitingConfirmation
}

public struct BackendFileTransfer: Codable, Equatable, Sendable {
    public let fileID: String
    public let byteCount: UInt64
    public let uniqueBytesSent: UInt64
    public let phase: BackendFileTransferPhase

    public init(fileID: String, byteCount: UInt64, uniqueBytesSent: UInt64, phase: BackendFileTransferPhase) {
        self.fileID = fileID
        self.byteCount = byteCount
        self.uniqueBytesSent = uniqueBytesSent
        self.phase = phase
    }
}

public struct BackendTransferResult: Codable, Equatable, Sendable {
    public let files: [BackendFileTransfer]
    public let peerRequestedExit: Bool
    public let totalBytesSent: UInt64

    public init(files: [BackendFileTransfer], peerRequestedExit: Bool, totalBytesSent: UInt64) {
        self.files = files
        self.peerRequestedExit = peerRequestedExit
        self.totalBytesSent = totalBytesSent
    }
}

public enum BackendError: Error, LocalizedError, Sendable, Equatable {
    case invalidPlan
    case protocolViolation
    case unsupportedCommand
    case unknownFile
    case rangeOutOfBounds
    case sourceChanged
    case shortRead
    case timeout
    case disconnected
    case cancelled
    case busy
    case unavailable
    case transport
    case releaseUnverified

    public var errorDescription: String? {
        switch self {
        case .invalidPlan: "Backend 文件计划无效。"
        case .protocolViolation: "Backend 返回了无效或不一致的协议数据。"
        case .unsupportedCommand: "Backend 请求了当前未支持的命令。"
        case .unknownFile: "Backend 请求的文件不在本次计划中。"
        case .rangeOutOfBounds: "Backend 请求的文件范围超出边界。"
        case .sourceChanged: "计划中的源文件已发生变化，需要重新预检。"
        case .shortRead: "无法完整读取所请求的文件范围。"
        case .timeout: "Backend 操作超时，设备安装结果尚未确认。"
        case .disconnected: "Backend 连接已断开，设备安装结果尚未确认。"
        case .cancelled: "Backend 操作已取消，设备安装结果尚未确认。"
        case .busy: "已有设备操作正在进行。"
        case .unavailable: "Backend 传输通道当前不可用。"
        case .transport: "Backend USB 传输失败，设备安装结果尚未确认。"
        case .releaseUnverified: "无法确认 Backend 会话已释放，当前不能开始新的会话。"
        }
    }
}
