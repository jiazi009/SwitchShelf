import Foundation

/// Metadata observed in one MTP session. Storage descriptions identify a supported
/// projection, not the server executable/version or a persistent console identity.
public struct MTPInventoryEvidence: Codable, Sendable, Equatable {
    public var reportedStorageCount: Int
    public var reportedStorageNames: [String]
    public var inventoryStorageNames: [String]
    public var gameDirectoryCount: Int
    public var metadataObjectCount: Int
    public var storageDiagnosticsOnly: Bool

    public init(reportedStorageCount: Int, reportedStorageNames: [String],
                inventoryStorageNames: [String], gameDirectoryCount: Int = 0,
                metadataObjectCount: Int = 0, storageDiagnosticsOnly: Bool = false) {
        self.reportedStorageCount = reportedStorageCount
        self.reportedStorageNames = reportedStorageNames
        self.inventoryStorageNames = inventoryStorageNames
        self.gameDirectoryCount = gameDirectoryCount
        self.metadataObjectCount = metadataObjectCount
        self.storageDiagnosticsOnly = storageDiagnosticsOnly
    }
}
