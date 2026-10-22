import Foundation
import Testing
@testable import SwitchShelfDomain

private let baseID = "0100123456780000"
private let updateID = "0100123456780800"
private func content(_ id: String, kind: ContentKind, version: UInt32? = nil) -> LocalContent {
    LocalContent(id: "\(id)-\(version ?? 0)", titleID: id, kind: kind, rawVersion: version, fileURL: URL(fileURLWithPath: "/fixture/test.nsp"), byteCount: 1, format: .nsp)
}
private func game(_ extra: [LocalContent] = [], confidence: IdentificationState = .matched) -> Game {
    Game(id: baseID, title: "测试游戏", contents: [content(baseID, kind: .base)] + extra, identification: confidence)
}
private func record(_ id: String?, kind: ContentKind, version: UInt32? = nil) -> InstalledRecord {
    InstalledRecord(id: UUID().uuidString, titleID: id, kind: kind, rawVersion: version, name: "fixture", objectPath: "/Installed games/fixture")
}
private func inventory(_ records: [InstalledRecord], complete: Bool = true) -> InstalledInventory {
    InstalledInventory(deviceID: "test-session", isComplete: complete, records: records)
}
@Test func absenceNeedsCompleteIdentityCoverage() {
    #expect(InstallationAssessor.assess(game(), inventory: inventory([], complete: false), isCurrentSession: true).state == .unknown)
    #expect(InstallationAssessor.assess(game(), inventory: inventory([record(nil, kind: .unknown)]), isCurrentSession: true).state == .unknown)
    #expect(InstallationAssessor.assess(game(), inventory: inventory([]), isCurrentSession: true).state == .notInstalled)
}
@Test func positiveBaseEvidenceSurvivesIncompleteTraversal() {
    #expect(InstallationAssessor.assess(game(), inventory: inventory([record(baseID, kind: .base)], complete: false), isCurrentSession: true).state == .installed)
}
@Test func oldSessionAndUnconfirmedLocalIdentityStayUnknown() {
    let data = inventory([record(baseID, kind: .base)])
    #expect(InstallationAssessor.assess(game(), inventory: data, isCurrentSession: false).state == .unknown)
    #expect(InstallationAssessor.assess(game(confidence: .needsReview), inventory: data, isCurrentSession: true).state == .unknown)
}
@Test func updateWithoutBaseIsPartial() {
    let g = game([content(updateID, kind: .update, version: 2)])
    #expect(InstallationAssessor.assess(g, inventory: inventory([record(updateID, kind: .update, version: 2)]), isCurrentSession: true).state == .partial)
}
@Test func highestComparableUpdateWinsAndNewerInstalledCoversOlder() {
    let g = game([content(updateID, kind: .update, version: 1), content(updateID, kind: .update, version: 2)])
    #expect(InstallationAssessor.assess(g, inventory: inventory([record(baseID, kind: .base), record(updateID, kind: .update, version: 3)]), isCurrentSession: true).state == .installed)
    #expect(InstallationAssessor.assess(g, inventory: inventory([record(baseID, kind: .base), record(updateID, kind: .update, version: 1)]), isCurrentSession: true).state == .partial)
}
@Test func unknownUpdateVersionDoesNotAssertUpgrade() {
    let g = game([content(updateID, kind: .update)])
    let result = InstallationAssessor.assess(g, inventory: inventory([record(baseID, kind: .base), record(updateID, kind: .update)]), isCurrentSession: true)
    #expect(result.state == .installed)
    #expect(result.explanation.contains("未知"))
}
@Test func onlyCanonicalHexIDsAccepted() {
    #expect(InstallationAssessor.normalizedID("0100abcdef120000") == "0100ABCDEF120000")
    #expect(InstallationAssessor.normalizedID(" 0100123456780000") == nil)
    #expect(InstallationAssessor.normalizedID("010012345678000G") == nil)
}
