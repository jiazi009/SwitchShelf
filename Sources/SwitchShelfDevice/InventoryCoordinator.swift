import Foundation
import SwitchShelfDomain

/// A reentrancy gate holds across awaits and across all public inventory services.
actor InventoryCoordinator {
    static let shared = InventoryCoordinator()
    private var busy = false
    func read(storageDiagnosticsOnly: Bool = false) async throws -> InstalledInventory {
        guard !busy else { throw DeviceServiceError(code: .busy, message: "只读清单会话正在进行；请等待完成。") }
        busy = true
        defer { busy = false }
        let transport = try await LibUSBInventoryTransport.connect()
        do {
            var inventory = try await InventoryReader().read(from: transport, storageDiagnosticsOnly: storageDiagnosticsOnly)
            do { try await transport.close() }
            catch {
                inventory.isComplete = false
                inventory.issues.append("MTP session release failed; reconnect and verify before relying on this snapshot.")
            }
            return inventory
        } catch {
            try? await transport.close()
            throw error
        }
    }
}
