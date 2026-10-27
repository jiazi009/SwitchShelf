import Foundation
import Testing
@testable import SwitchShelfDomain

@Suite("Automatic update selection")
struct UpdateSelectionTests {
    func item(_ id: String, _ version: UInt32?, kind: ContentKind = .update) -> LocalContent {
        LocalContent(id: id, kind: kind, rawVersion: version,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id).nsp"), byteCount: 1, format: .nsp)
    }
    @Test func latestRawVersionWinsRegardlessOfOrder() {
        #expect(UpdateSelection.defaultID(in: [item("base", nil, kind: .base), item("old", 65536), item("new", 131072)]) == "new")
        #expect(UpdateSelection.defaultID(in: [item("new", 131072), item("old", 65536)]) == "new")
    }
    @Test func ambiguousVersionsRequireManualSelection() {
        #expect(UpdateSelection.defaultID(in: [item("a", 65536), item("b", nil)]) == nil)
        #expect(UpdateSelection.defaultID(in: [item("a", 65536), item("b", 65536)]) == nil)
        #expect(UpdateSelection.defaultID(in: [item("a", nil), item("b", nil)]) == nil)
    }
    @Test func oneCandidateAndNoCandidates() {
        #expect(UpdateSelection.defaultID(in: [item("only", nil)]) == "only")
        #expect(UpdateSelection.defaultID(in: [item("base", nil, kind: .base)]) == nil)
    }
    @Test func manualReplacementAndLegacyConflict() {
        let updates: Set<String> = ["old", "new", "other"]
        let legacy: Set<String> = ["base", "old", "new", "dlc"]
        #expect(UpdateSelection.hasConflict(updateIDs: updates, selectedIDs: legacy))
        let reduced = UpdateSelection.applying(id: "old", included: false, updateIDs: updates, selectedIDs: legacy)
        #expect(reduced == ["base", "new", "dlc"])
        #expect(!UpdateSelection.hasConflict(updateIDs: updates, selectedIDs: reduced))
        let replaced = UpdateSelection.applying(id: "other", included: true, updateIDs: updates, selectedIDs: legacy)
        #expect(replaced == ["base", "other", "dlc"])
    }

    @Test func queueTargetAndContentOrder() {
        #expect(InstallQueueRules.targetsAreConsistent(["sd", "sd"]))
        #expect(!InstallQueueRules.targetsAreConsistent(["sd", "nand"]))
        #expect([ContentKind.dlc, .base, .update, .unknown].sorted {
            InstallQueueRules.order($0) < InstallQueueRules.order($1)
        } == [.base, .update, .dlc, .unknown])
    }

}
