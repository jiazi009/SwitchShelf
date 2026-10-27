import Foundation

public enum InstallQueueRules {
    /// Targets are local intent; sphaira still controls the actual destination.
    public static func targetsAreConsistent(_ targets: [String]) -> Bool {
        Set(targets).count <= 1
    }
    public static func order(_ kind: ContentKind) -> Int {
        switch kind {
        case .base: 0
        case .update: 1
        case .dlc: 2
        case .unknown: 3
        }
    }
}
