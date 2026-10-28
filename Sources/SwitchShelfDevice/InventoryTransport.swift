import Foundation

struct MTPStorage: Sendable, Equatable { let id: UInt32; let name: String }
struct MTPObject: Sendable, Equatable {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let isFolder: Bool
}
protocol InventoryTransport: Sendable {
    func storages() async throws -> [MTPStorage]
    func children(storage: UInt32, parent: UInt32) async throws -> [UInt32]
    func object(id: UInt32) async throws -> MTPObject
    func close() async throws
}

