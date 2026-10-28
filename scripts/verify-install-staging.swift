import AppKit
import Darwin
import Foundation
import SwitchShelfDomain
import SwitchShelfDevice

/// Runs inside the isolated production WindowGroup harness. Only tiny local
/// fixture files are created; no bootstrap, USB worker or confirmation is run.
extension AppModel {
    func runInstallStagingRegression() async throws {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "InstallStagingRegression", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!)
            .appendingPathComponent("staging-files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let resolved = realpath(root.path, nil) else { throw CocoaError(.fileReadUnknown) }
        let canonicalRoot = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        free(resolved)
        func file(_ id: String, _ kind: ContentKind, _ version: UInt32?, identity: String? = "0100000000000800") throws -> LocalContent {
            let url = canonicalRoot.appendingPathComponent("\(id).nsp")
            try Data([1, 2, 3]).write(to: url)
            return LocalContent(id: id, titleID: identity, kind: kind, rawVersion: version,
                                fileURL: url, byteCount: 3, format: .nsp, availability: .online)
        }
        let base = try file("base", .base, 0, identity: "0100000000000000")
        let older = try file("older", .update, 65_536)
        let latest = try file("latest", .update, 131_072)
        let dlc = try file("dlc", .dlc, 0, identity: "0100000000001001")
        let a = Game(id: "stage-a", title: "Stage A", contents: [base, older, latest, dlc])
        let b = Game(id: "stage-b", title: "Stage B", contents: [try file("b-base", .base, 0)])
        let source = LibrarySource(id: "staging-source", url: canonicalRoot, name: "Synthetic only", availability: .online)
        let snapshot = LibrarySnapshot(sources: [source], games: [a, b])
        seedUIReview(snapshot, plan: [], page: .all, layout: .grid, inspector: false)
        try await verifyNativeCardEvents(first: a, second: b)
        clearPlan()
        layout = .list
        try await verifyNativeCardEvents(first: a, second: b)
        clearPlan()
        layout = .grid
        handleGridTap(a, modifiers: [])
        try check(plan.count == 1 && Set(plan[0].includedContents.map(\.id)) == [base.id, latest.id, dlc.id],
                  "Default selection must include base, all DLC and unique newest explicit update")
        try check(detailGame == nil, "Card selection must not open details")
        updatePlanTarget(a.id, target: .nand)
        setPlanContentIncluded(a.id, contentID: older.id, included: true)
        let explicit = plan
        handleGridTap(a, modifiers: [])
        try check(plan == explicit, "Duplicate click changed explicit selection or target")
        let persisted = try JSONDecoder().decode([PlanItem].self, from: JSONEncoder().encode(explicit))
        seedUIReview(snapshot, plan: persisted, page: .all, layout: .grid, inspector: false)
        addToQueue(a)
        try check(plan == explicit, "Persisted manual selection or target was overwritten")
        handleGridTap(b, modifiers: [])
        try check(plan.map(\.gameID) == [a.id, b.id], "Multiple card clicks must accumulate")
        try check(!queueValidationIssues.isEmpty, "Mixed targets must block installation")
        setAllPlanTargets(.sd)
        try check(plan.allSatisfy { $0.target == .sd } && queueValidationIssues.isEmpty, "Explicit target unification failed")
        let beforeDetails = plan
        let selectionBeforeDetails = selectedGameIDs
        openGameDetails(a)
        try await Task.sleep(for: .milliseconds(250))
        try check(plan == beforeDetails && selectedGameIDs == selectionBeforeDetails && detailGame?.id == a.id,
                  "Details must be independent of staging and selection")
        closeGameDetails()
        try await Task.sleep(for: .milliseconds(250))
        try check(plan == beforeDetails && detailGame == nil, "Closing details changed staging")
        movePlanItem(b.id, direction: -1)
        try check(plan.map(\.gameID) == [b.id, a.id], "Staging order did not move")
        removePlanItem(b.id)
        try check(plan.count == 1 && plan[0].gameID == a.id, "Remove staging item failed")
        try check(games == snapshot.games && sources == snapshot.sources, "Staging mutated the source snapshot")

        var unknown = latest; unknown.id = "unknown"; unknown.rawVersion = nil
        var tied = latest; tied.id = "tied"
        var differentIdentity = latest; differentIdentity.id = "other-identity"; differentIdentity.titleID = "0100000000001800"
        var missingIdentity = latest; missingIdentity.titleID = nil
        for candidates in [[unknown], [older, unknown], [latest, tied], [older, differentIdentity], [missingIdentity]] {
            try check(InstallContentDefaults.latestUpdateID(in: candidates) == nil,
                      "Ambiguous update identity/version was guessed")
        }
        let uncertain = Game(id: "uncertain", title: "Uncertain update", contents: [base, unknown])
        seedUIReview(LibrarySnapshot(sources: [source], games: [uncertain]), plan: [], page: .all, layout: .grid, inspector: false)
        addToQueue(uncertain)
        try check(needsUpdateChoice(plan[0]) && !queueValidationIssues.isEmpty, "Ambiguous update must require explicit choice")
        try await Task.sleep(for: .milliseconds(250))
        try check(!canBeginStagedInstallation, "Unresolved update choice must block the start button")
        omitUpdatesForThisInstallation(uncertain.id)
        try check(!needsUpdateChoice(plan[0]) && plan[0].includedContents.allSatisfy { $0.kind != .update },
                  "Explicit update omission was not honored")
        removePlanItem(uncertain.id)
        addToQueue(uncertain)
        try check(needsUpdateChoice(plan[0]), "New task reused an old omission acknowledgement")
        setPlanContentIncluded(uncertain.id, contentID: unknown.id, included: true)
        try check(!needsUpdateChoice(plan[0]), "Explicit update file choice was not honored")

        let locked = plan
        installationReview = SphairaBatchReview(items: [])
        addToQueue(b); removePlanItem(uncertain.id); clearPlan(); setAllPlanTargets(.nand)
        setPlanContentIncluded(uncertain.id, contentID: base.id, included: false)
        try check(plan == locked && installationPlanLocked, "Review must lock staging edits")
        cancelInstallationReview()
        await beginStagedInstallation()
        try check(installationReview == nil && !isInstalling && !isPreparingInstallation && showConnectionGuide,
                  "Disconnected start must show guidance without launching an installer")
        showConnectionGuide = false

        // Metadata-only integration: fake descriptor evidence is scoped to this
        // harness, never an actual device result. Only a review sheet is allowed.
        seedUIReview(snapshot, plan: [], page: .all, layout: .grid, inspector: false)
        addToQueue(a)
        seedUIReviewDevice(DeviceDiscovery(state: .waitingForMTP,
            devices: [DeviceDescriptor(id: "fixture-usb", name: "Synthetic USB candidate", vendorID: 0x057e, productID: 0x201d)],
            message: "Synthetic descriptor only; no USB opened"))
        if installationConnectionBlocker == nil {
            try await Task.sleep(for: .milliseconds(350))
            guard let button = WindowLayoutEvidence.frames["installButton"],
                  let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }) else {
                throw NSError(domain: "InstallStartEvent", code: 1)
            }
            try WindowLayoutEvidence.press(button, in: window)
            try WindowLayoutEvidence.press(button, in: window)
            try await Task.sleep(for: .milliseconds(600))
            print("Review fixture: prepared=\(preparation?.isPrepared == true), offers=\(preparation?.offers.count ?? 0), review=\(installationReview?.items.count ?? 0), issues=\(preparation?.issues.map { $0.message } ?? []), notice=\(notice?.message ?? "none")")
            try check(preparationIsCurrent && preparation?.isPrepared == true && installationReview?.items.count == 3,
                      "Start must automatically preflight and prepare a review from the library page")
            try check(!isInstalling && installationPlanLocked, "Preparing a review must not send files")
            try await Task.sleep(for: .milliseconds(350))
            cancelInstallationReview()
        } else {
            print("External MTP client/busy condition respected; review integration not forced.")
        }
        try check(!isInstalling, "Regression must never launch a physical installation")
        clearPlan()
        var rich = snapshot
        rich.games[0].title = String(repeating: "很长的合成游戏标题用于检查待选区布局", count: 3)
        rich.sources[0].name = "很长的合成离线来源名称用于布局检查"
        rich.sources[0].availability = .offline
        seedUIReview(rich, plan: rich.games.map { PlanItem(game: $0) }, page: .all, layout: .grid, inspector: true)
        try await Task.sleep(for: .seconds(1))
        clearPlan()
        seedUIReviewDevice(DeviceDiscovery(state: .disconnected, message: "Fixture complete; no real USB access"))
        print("PASS: staging accumulation/dedup/order/removal, defaults/ambiguity, independent details, locked edits, disconnected guidance and metadata-only start/review.")
    }

    private func verifyNativeCardEvents(first: Game, second: Game) async throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "NativeCardEvents", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func press(_ frame: CGRect, in window: NSWindow) throws {
            // Dispatch to this fixture's own window, never system-wide events.
            try WindowLayoutEvidence.press(frame, in: window)
        }
        try await Task.sleep(for: .milliseconds(500))
        guard let window = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet }),
              let info = WindowLayoutEvidence.frames["details-\(first.id)"] else {
            throw NSError(domain: "NativeCardEvents", code: 3)
        }
        let sidebar = WindowLayoutEvidence.frames["staging"]
        try press(info, in: window)
        try await Task.sleep(for: .milliseconds(500))
        try require(detailGame?.id == first.id && plan.isEmpty, "Actual info-button click also staged the game or did not open details")
        try require(WindowLayoutEvidence.frames["staging"] == sidebar, "Detail popover moved the staging sidebar")
        guard let popup = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }),
              let close = WindowLayoutEvidence.frames["details-close"] else {
            throw NSError(domain: "NativeCardEvents", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing independent popover/close button"])
        }
        try press(close, in: popup)
        try await Task.sleep(for: .milliseconds(400))
        try require(detailGame == nil && plan.isEmpty, "Actual close-button click failed or changed staging")
        for game in [first, second, first] {
            let prefix = layout == .grid ? "card" : "row"
            guard let card = WindowLayoutEvidence.frames["\(prefix)-\(game.id)"] else { throw NSError(domain: "NativeCardEvents", code: 5) }
            try press(card, in: window)
            try await Task.sleep(for: .milliseconds(450))
            print("Native card \(game.id), frame=\(card), plan=\(plan.map { $0.gameID }), detail=\(detailGameID ?? "nil")")
            guard let cover = WindowLayoutEvidence.frames["staging-cover-\(game.id)"],
                  let destination = WindowLayoutEvidence.frames["staging"] else { throw NSError(domain: "NativeCardEvents", code: 6) }
            try require(cover.minX >= destination.minX - 1 && cover.maxX <= destination.maxX + 1
                        && abs(cover.width - 46) < 1 && abs(cover.height - 60) < 1,
                        "Staging artwork did not settle at its own sidebar thumbnail bounds")
        }
        try require(plan.map(\.gameID) == [first.id, second.id], "Actual body clicks failed accumulation or deduplication")
        try require(detailGame == nil, "Actual body click opened details")
        print("PASS: actual in-process AppKit mouse events: info/close isolated from staging; card-body accumulation/dedup and animation settle.")
    }
}
