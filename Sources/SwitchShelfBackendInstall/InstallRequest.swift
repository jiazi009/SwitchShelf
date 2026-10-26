import Foundation
import SwitchShelfBackend

/// Local locations shared with the app and probe. The journal is host-exchange
/// evidence only; it is never a device-installation report.
public enum BackendInstallLocation {
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwitchShelf", isDirectory: true)
    }

    public static var defaultJournalURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("backend", isDirectory: true)
            .appendingPathComponent("journal.json")
    }
}

/// One reviewed, host-driven Backend attempt for exactly one local package file.
public struct BackendInstallRequest: Sendable {
    public let fileURL: URL
    public let journalURL: URL
    public let sessionTimeoutSeconds: Int
    public let maximumChunkSize: Int
    public let operationTimeoutMilliseconds: UInt32
    public let intendedTarget: String
    /// Called after each durable journal record. Values are conservative host-side
    /// coverage, never proof of device installation.
    public let progress: (@Sendable (UInt64, UInt64) -> Void)?

    public init(fileURL: URL,
                journalURL: URL = BackendInstallLocation.defaultJournalURL,
                sessionTimeoutSeconds: Int = 1_800,
                maximumChunkSize: Int = 262_144,
                operationTimeoutMilliseconds: UInt32 = 15_000,
                intendedTarget: String = "sd",
                progress: (@Sendable (UInt64, UInt64) -> Void)? = nil) {
        self.fileURL = fileURL
        self.journalURL = journalURL
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        self.maximumChunkSize = maximumChunkSize
        self.operationTimeoutMilliseconds = operationTimeoutMilliseconds
        self.intendedTarget = intendedTarget
        self.progress = progress
    }
}

public enum BackendInstallOutcome: String, Codable, Sendable {
    /// The host sent every requested byte and the device requested EXIT.
    /// This still does not prove the device installed or retained anything.
    case transferredAwaitingConfirmation
    /// The attempt ended (timeout/disconnect/EXIT) without full host-side coverage.
    case incompleteTransfer
    case failed
    case cancelled
    case deviceBusy
    case deviceUnavailable
    case journalUnavailable

    public var exitCode: Int32 {
        switch self {
        case .transferredAwaitingConfirmation: 0
        case .failed: 1
        case .incompleteTransfer: 2
        case .deviceUnavailable: 3
        case .deviceBusy: 4
        case .journalUnavailable: 5
        case .cancelled: 130
        }
    }
}

public struct BackendInstallReport: Codable, Sendable {
    public let outcome: BackendInstallOutcome
    public let message: String
    public let fileName: String
    public let filePath: String
    public let byteCount: UInt64
    public let uniqueBytesSent: UInt64
    public let peerRequestedExit: Bool
    public let attemptID: String?
    public let journalPath: String
    public let journalState: String?
    public let startedAt: Date
    public let finishedAt: Date
    public let notes: [String]

    public var exitCode: Int32 { outcome.exitCode }
}
