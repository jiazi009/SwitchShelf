import SwitchShelfDomain

/// Compares observed records only; it does not establish that the same console supplied them.
public enum InventorySnapshotComparison: Equatable, Sendable {
    case incomplete
    case changes(added: Int, missing: Int)

    public static func compare(_ old: InstalledInventory, _ new: InstalledInventory) -> Self {
        guard old.isComplete, new.isComplete else { return .incomplete }
        func keys(_ inventory: InstalledInventory) -> Set<RecordKey> {
            Set(inventory.records.map {
                RecordKey(path: $0.objectPath, titleID: $0.titleID, kind: $0.kind.rawValue, version: $0.rawVersion)
            })
        }
        let before = keys(old), after = keys(new)
        return .changes(added: after.subtracting(before).count, missing: before.subtracting(after).count)
    }

    private struct RecordKey: Hashable {
        let path: String
        let titleID: String?
        let kind: String
        let version: UInt32?
    }
}
