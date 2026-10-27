import Foundation

/// Filename-derived versions are candidates, not verification of package contents.
public enum UpdateSelection {
    public static func defaultID(in contents: [LocalContent]) -> String? {
        let updates = contents.filter { $0.kind == .update }
        guard !updates.isEmpty else { return nil }
        if updates.count == 1 { return updates[0].id }
        guard updates.allSatisfy({ $0.rawVersion != nil }),
              let highest = updates.compactMap(\.rawVersion).max() else { return nil }
        let candidates = updates.filter { $0.rawVersion == highest }
        return candidates.count == 1 ? candidates[0].id : nil
    }
    /// A newly selected update replaces all other selected updates. Deselecting
    /// preserves any legacy conflicts so the user can resolve them explicitly.
    public static func applying(id: String, included: Bool, updateIDs: Set<String>, selectedIDs: Set<String>) -> Set<String> {
        var result = selectedIDs
        if included {
            if updateIDs.contains(id) { result.subtract(updateIDs) }
            result.insert(id)
        } else { result.remove(id) }
        return result
    }

    public static func hasConflict(updateIDs: Set<String>, selectedIDs: Set<String>) -> Bool {
        updateIDs.intersection(selectedIDs).count > 1
    }

}
