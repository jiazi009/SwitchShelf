import Foundation
import SwitchShelfDomain

/// A historical snapshot for display only. It never establishes a current connection.
public actor InventoryCache {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("last-device-inventory.json") }

    public init(directory: URL) { self.directory = directory }

    public func load() -> InstalledInventory? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstalledInventory.self, from: data)
    }

    public func save(_ inventory: InstalledInventory) throws {
        var snapshot = inventory
        snapshot.deviceID = "cached-inventory" // MTP session IDs are not durable device identities.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: file, options: .atomic)
    }
}
