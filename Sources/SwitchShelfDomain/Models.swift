import Foundation

public enum ContentKind: String, Codable, Sendable, CaseIterable {
    case base, update, dlc, unknown
}
public enum PackageFormat: String, Codable, Sendable, CaseIterable {
    case nsp, xci, nsz, xcz
}
public enum SourceAvailability: String, Codable, Sendable { case online, offline, unknown }
public enum IdentificationState: String, Codable, Sendable { case verified, matched, needsReview, unidentified }

public struct LibrarySource: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var url: URL
    public var name: String
    public var availability: SourceAvailability
    public var bookmark: Data?
    public init(id: String = UUID().uuidString, url: URL, name: String, availability: SourceAvailability = .unknown, bookmark: Data? = nil) {
        self.id = id; self.url = url; self.name = name; self.availability = availability; self.bookmark = bookmark
    }
}
public struct LocalContent: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var titleID: String?
    public var kind: ContentKind
    public var rawVersion: UInt32?
    public var displayVersion: String?
    public var fileURL: URL
    public var byteCount: Int64
    public var format: PackageFormat
    public var availability: SourceAvailability
    public init(id: String, titleID: String? = nil, kind: ContentKind = .unknown, rawVersion: UInt32? = nil, displayVersion: String? = nil, fileURL: URL, byteCount: Int64, format: PackageFormat, availability: SourceAvailability = .online) {
        self.id = id; self.titleID = titleID; self.kind = kind; self.rawVersion = rawVersion; self.displayVersion = displayVersion
        self.fileURL = fileURL; self.byteCount = byteCount; self.format = format; self.availability = availability
    }
}
public struct Game: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var originalTitle: String?
    public var coverURL: URL?
    public var contents: [LocalContent]
    public var identification: IdentificationState
    public init(id: String, title: String, originalTitle: String? = nil, coverURL: URL? = nil, contents: [LocalContent] = [], identification: IdentificationState = .needsReview) {
        self.id = id; self.title = title; self.originalTitle = originalTitle; self.coverURL = coverURL; self.contents = contents; self.identification = identification
    }
    public var byteCount: Int64 { contents.reduce(0) { $0 + $1.byteCount } }
}
public struct LibrarySnapshot: Codable, Sendable, Equatable {
    public var sources: [LibrarySource]
    public var games: [Game]
    public var scannedAt: Date?
    public var issues: [String]
    public init(sources: [LibrarySource] = [], games: [Game] = [], scannedAt: Date? = nil, issues: [String] = []) {
        self.sources = sources; self.games = games; self.scannedAt = scannedAt; self.issues = issues
    }
}
public protocol LibraryScanning: Sendable {
    func scan(_ source: LibrarySource) async throws -> LibrarySnapshot
}
public protocol LibraryPersisting: Sendable {
    func load() async throws -> LibrarySnapshot
    func save(_ snapshot: LibrarySnapshot) async throws
}

public enum DeviceConnectionState: String, Codable, Sendable {
    case disconnected, detected, waitingForMTP, ready, reading, busy, error
}
public struct DeviceDescriptor: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var vendorID: UInt16
    public var productID: UInt16
    public init(id: String, name: String, vendorID: UInt16, productID: UInt16) {
        self.id = id; self.name = name; self.vendorID = vendorID; self.productID = productID
    }
}
public struct DeviceDiscovery: Codable, Sendable, Equatable {
    public var state: DeviceConnectionState
    public var devices: [DeviceDescriptor]
    public var message: String
    public init(state: DeviceConnectionState, devices: [DeviceDescriptor] = [], message: String) {
        self.state = state; self.devices = devices; self.message = message
    }
}
public struct InstalledRecord: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var titleID: String?
    public var kind: ContentKind
    public var rawVersion: UInt32?
    public var name: String
    public var objectPath: String
    public init(id: String, titleID: String? = nil, kind: ContentKind = .unknown, rawVersion: UInt32? = nil, name: String, objectPath: String) {
        self.id = id; self.titleID = titleID; self.kind = kind; self.rawVersion = rawVersion; self.name = name; self.objectPath = objectPath
    }
}
public struct InstalledInventory: Codable, Sendable, Equatable {
    public var deviceID: String
    public var environmentContext: String?
    public var observedAt: Date
    public var isComplete: Bool
    public var records: [InstalledRecord]
    public var issues: [String]
    /// Optional so inventories produced by earlier helpers still decode.
    public var mtpEvidence: MTPInventoryEvidence?
    public init(deviceID: String, environmentContext: String? = nil, observedAt: Date = Date(), isComplete: Bool = false, records: [InstalledRecord] = [], issues: [String] = [], mtpEvidence: MTPInventoryEvidence? = nil) {
        self.deviceID = deviceID; self.environmentContext = environmentContext; self.observedAt = observedAt
        self.isComplete = isComplete; self.records = records; self.issues = issues
        self.mtpEvidence = mtpEvidence
    }
}
public enum InstallationState: String, Codable, Sendable { case installed, notInstalled, partial, unknown }
public struct InstallationAssessment: Codable, Sendable, Equatable {
    public var state: InstallationState
    public var explanation: String
    public var observedAt: Date?
    public init(state: InstallationState, explanation: String, observedAt: Date? = nil) {
        self.state = state; self.explanation = explanation; self.observedAt = observedAt
    }
}

