import Foundation
import Testing
@testable import SwitchShelfDomain

private let baseID = "0100123456780000"
private let updateID = "0100123456780800"
private func content(_ id: String, kind: ContentKind, version: UInt32? = nil) -> LocalContent {
    LocalContent(id: "\(id)-\(version ?? 0)", titleID: id, kind: kind, rawVersion: version, fileURL: URL(fileURLWithPath: "/fixture/test.nsp"), byteCount: 1, format: .nsp)
}
private func game(_ extra: [LocalContent] = [], confidence: IdentificationState = .verified) -> Game {
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
    #expect(InstallationAssessor.assess(game(confidence: .unidentified), inventory: data, isCurrentSession: true).state == .unknown)
    let matched = game(confidence: .matched)
    #expect(InstallationAssessor.assess(matched, inventory: data, isCurrentSession: false).state == .unknown)
    #expect(InstallationAssessor.assess(matched, inventory: nil, isCurrentSession: true).state == .unknown)
}
@Test func filenameTitleIDMatchesCurrentBaseWithoutBecomingVerified() {
    let matched = game(confidence: .matched)
    let data = inventory([record(baseID, kind: .base)])
    let filenameCandidate = InstallationAssessor.assess(matched, inventory: data, isCurrentSession: true)
    #expect(matched.identification == .matched)
    #expect(filenameCandidate.state == .installed)
    #expect(filenameCandidate.explanation.contains("文件名"))
    #expect(filenameCandidate.explanation.contains("未验证"))
    let base = matched.contents[0]
    let baseAssessment = InstallationAssessor.assess(base, in: matched, inventory: data, isCurrentSession: true)
    #expect(baseAssessment.state == .installed)
    #expect(baseAssessment.explanation.contains("文件名"))
}
@Test func filenameBaseWithMissingOrOlderUpdateOrDLCIsPartial() {
    let update = content(updateID, kind: .update, version: 2)
    let dlcID = "0100123456781001"
    let missingUpdate = game([update], confidence: .matched)
    let missing = InstallationAssessor.assess(missingUpdate, inventory: inventory([record(baseID, kind: .base)]), isCurrentSession: true)
    #expect(missing.state == .partial)
    #expect(missing.explanation.contains("文件名"))
    #expect(InstallationAssessor.assess(missingUpdate.contents[0], in: missingUpdate, inventory: inventory([record(baseID, kind: .base)]), isCurrentSession: true).state == .installed)
    #expect(InstallationAssessor.assess(update, in: missingUpdate, inventory: inventory([record(baseID, kind: .base)]), isCurrentSession: true).state == .notInstalled)

    let older = game([update], confidence: .matched)
    let olderInventory = inventory([record(baseID, kind: .base), record(updateID, kind: .update, version: 1)])
    #expect(InstallationAssessor.assess(older, inventory: olderInventory, isCurrentSession: true).state == .partial)
    #expect(InstallationAssessor.assess(update, in: older, inventory: olderInventory, isCurrentSession: true).state == .notInstalled)

    let dlc = content(dlcID, kind: .dlc, version: 2)
    let olderDLC = game([dlc], confidence: .matched)
    let dlcInventory = inventory([record(baseID, kind: .base), record(dlcID, kind: .dlc, version: 1)])
    #expect(InstallationAssessor.assess(olderDLC, inventory: dlcInventory, isCurrentSession: true).state == .partial)
}
@Test func filenameAbsenceAndIncompleteBaseEvidence() {
    let matched = game(confidence: .matched)
    let other = record("0100AAAABBBB0000", kind: .base)
    let absent = InstallationAssessor.assess(matched, inventory: inventory([other]), isCurrentSession: true)
    #expect(absent.state == .notInstalled)
    #expect(absent.explanation.contains("没有本体"))
    #expect(matched.identification == .matched)

    let updateOnly = game([content(updateID, kind: .update, version: 2)], confidence: .matched)
    #expect(InstallationAssessor.assess(updateOnly, inventory: inventory([record(updateID, kind: .update, version: 2)]), isCurrentSession: true).state == .notInstalled)

    let withUpdate = game([content(updateID, kind: .update, version: 5)], confidence: .matched)
    let incomplete = inventory([record(baseID, kind: .base)], complete: false)
    let positive = InstallationAssessor.assess(withUpdate, inventory: incomplete, isCurrentSession: true)
    #expect(positive.state == .installed)
    #expect(positive.explanation.contains("未验证"))
    #expect(InstallationAssessor.assess(game(confidence: .needsReview), inventory: incomplete, isCurrentSession: true).state == .unknown)
}
@Test func verifiedContentKeepsEvidenceWording() {
    let verified = game([content(updateID, kind: .update, version: 2)])
    let data = inventory([record(baseID, kind: .base), record(updateID, kind: .update, version: 2)])
    let contentAssessment = InstallationAssessor.assess(verified.contents[0], in: verified, inventory: data, isCurrentSession: true)
    #expect(contentAssessment.state == .installed)
    #expect(!contentAssessment.explanation.contains("文件名"))
    #expect(InstallationAssessor.assess(verified, inventory: data, isCurrentSession: true).explanation == "已确认本体存在，本地可比内容无已知缺项")
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
