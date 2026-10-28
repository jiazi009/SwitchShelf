import Foundation

/// Filename suffixes are candidates, not a reading of package contents.
/// `.xci` is treated as an integrated package and is preferred over a separate base.
public enum BaseSelection {
    /// IDs to preselect. `nil` means the choice is ambiguous and nothing should be guessed.
    /// One `.xci` base is installed alone: other bases, updates and DLC stay unchecked.
    public static func defaultIncludedIDs(in contents: [LocalContent], updateID: String?) -> Set<String>? {
        let bases = contents.filter { $0.kind == .base }
        let integrated = bases.filter { $0.format == .xci }
        if integrated.count == 1 { return [integrated[0].id] }
        if integrated.count > 1 || bases.count > 1 { return nil }
        var ids = Set(contents.filter { $0.kind == .dlc }.map(\.id))
        if let base = bases.first { ids.insert(base.id) }
        if let updateID { ids.insert(updateID) }
        return ids
    }

    public static func includesIntegratedBase(_ included: [(ContentKind, PackageFormat)]) -> Bool {
        included.contains { $0.0 == .base && $0.1 == .xci }
    }

    /// An integrated package is sent by itself. Extra bases, updates or DLC are a conflict.
    public static func integratedPackageHasCompany(_ included: [(ContentKind, PackageFormat)]) -> Bool {
        includesIntegratedBase(included) && included.count != 1
    }
}
