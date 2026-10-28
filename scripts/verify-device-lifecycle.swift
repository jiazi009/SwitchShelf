// Appended to a temporary copy of production AppModel.swift by the companion
// script so private lifecycle methods can be tested without widening app API.
import SwiftUI
import Darwin

private struct LifecycleFailure: Error, CustomStringConvertible {
    let description: String
}

private actor FixtureDiscovery {
    private var values: [DeviceDiscovery]
    private(set) var calls = 0
    init(_ values: [DeviceDiscovery]) { self.values = values }
    func next() -> DeviceDiscovery {
        calls += 1
        if values.count > 1 { return values.removeFirst() }
        return values[0]
    }
}

private struct LifecycleFixture {
    let model: AppModel
    let root: URL
    let probeMarker: URL
    let discovery: FixtureDiscovery
    let game: Game
    let inventory: InstalledInventory
}

@MainActor
private enum LifecycleChecks {
    static var count = 0
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw LifecycleFailure(description: message) }
        count += 1
    }
    static func candidate(_ id: String = "fixture-registry-A") -> DeviceDiscovery {
        DeviceDiscovery(state: .waitingForMTP, devices: [
            DeviceDescriptor(id: id, name: "Synthetic Switch", vendorID: 0x057e, productID: 0x201d)
        ], message: "Fixture only; no physical discovery")
    }
    static func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func probe(at root: URL, inventory: InstalledInventory, errorCode: String? = nil) throws -> (BoundedInventoryReader, URL) {
        let marker = root.appendingPathComponent("probe-starts")
        let executable = root.appendingPathComponent("fake-probe")
        let json: String
        let exitCode: Int
        if let errorCode {
            json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"transport\":\"libusb\",\"status\":\"error\",\"error\":{\"code\":\"\(errorCode)\",\"message\":\"fixture failure\"}}"
            exitCode = 1
        } else {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let encoded = String(decoding: try encoder.encode(inventory), as: UTF8.self)
            json = "{\"schemaVersion\":1,\"mode\":\"inventory\",\"transport\":\"libusb\",\"status\":\"\(inventory.isComplete ? "ok" : "partial")\",\"inventory\":\(encoded)}"
            exitCode = inventory.isComplete ? 0 : 2
        }
        let body = "#!/bin/sh\nprintf 'x\\n' >> \(shellQuote(marker.path))\nprintf '%s\\n' \(shellQuote(json))\nexit \(exitCode)\n"
        try Data(body.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (BoundedInventoryReader(probeURL: executable), marker)
    }
    static func probeCount(_ marker: URL) -> Int {
        (try? String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count) ?? 0
    }
}

extension AppModel {
    @MainActor fileprivate static func lifecycleFixture(
        root: URL, label: String, devices: [DeviceDiscovery]? = nil, errorCode: String? = nil
    ) throws -> LifecycleFixture {
        let directory = root.appendingPathComponent(label, isDirectory: true)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        func file(_ name: String, id: String, kind: ContentKind, version: UInt32) throws -> LocalContent {
            let url = source.appendingPathComponent(name)
            try Data(repeating: 0x46, count: 64).write(to: url)
            return LocalContent(id: url.path, titleID: id, kind: kind, rawVersion: version,
                                fileURL: url, byteCount: 64, format: .nsp)
        }
        let base = try file("Base [0100AAAA00000000][v0].nsp", id: "0100AAAA00000000", kind: .base, version: 0)
        let update = try file("Update [0100AAAA00000800][v65536].nsp", id: "0100AAAA00000800", kind: .update, version: 65_536)
        let newer = try file("Newer [0100AAAA00000800][v131072].nsp", id: "0100AAAA00000800", kind: .update, version: 131_072)
        let unrelatedBase = try file("Other [0100BBBB00000000][v0].nsp", id: "0100BBBB00000000", kind: .base, version: 0)
        let game = Game(id: "fixture-selected", title: "Synthetic selected game", contents: [base, update, newer], identification: .matched)
        let other = Game(id: "fixture-unselected", title: "Synthetic unselected game", contents: [unrelatedBase], identification: .matched)
        let records = [base, update].map {
            InstalledRecord(id: $0.id, titleID: $0.titleID, kind: $0.kind, rawVersion: $0.rawVersion,
                            name: $0.fileURL.lastPathComponent, objectPath: "Games/Synthetic/\($0.fileURL.lastPathComponent)")
        }
        let inventory = InstalledInventory(deviceID: "fixture-inventory", isComplete: true, records: records)
        let (reader, marker) = try LifecycleChecks.probe(at: directory, inventory: inventory, errorCode: errorCode)
        let discovery = FixtureDiscovery(devices ?? [LifecycleChecks.candidate()])
        let model = AppModel(appDirectory: directory.appendingPathComponent("state"), inventoryReader: reader,
                             discoverDevice: { await discovery.next() })
        model.snapshot = LibrarySnapshot(sources: [LibrarySource(url: source, name: "Synthetic source", availability: .online)], games: [game, other])
        var selected = PlanItem(game: game)
        for index in selected.contents.indices { selected.contents[index].included = selected.contents[index].id != newer.id }
        var unselected = PlanItem(game: other)
        for index in unselected.contents.indices { unselected.contents[index].included = false }
        model.plan = [selected, unselected]
        model.installStatuses = try [base, update].map {
            let request: SphairaInstallRequest
            do {
                request = try SphairaInstallRequest.review(sourceURL: $0.fileURL, allowedRoot: source,
                                                           expectedBytes: 64, intendedTarget: "sd")
            } catch {
                throw LifecycleFailure(description: "Fixture review failed: \($0.fileURL.path) under \(source.path); canonical \($0.fileURL.resolvingSymlinksInPath().path): \(error)")
            }
            return SphairaBatchStatus(item: SphairaBatchItem(gameTitle: game.title, request: request), state: .transferred, bytesSubmitted: 64)
        }
        model.deviceDiscovery = LifecycleChecks.candidate()
        model.inventory = inventory
        model.inventorySessionSignature = "fixture-registry-A"
        model.cachedInventory = inventory
        model.isVerifyingInstall = true
        return LifecycleFixture(model: model, root: directory, probeMarker: marker, discovery: discovery,
                                game: game, inventory: inventory)
    }

    @MainActor fileprivate static func runDeviceLifecycleRegression(root: URL) async throws {
        let require = LifecycleChecks.require
        let evidence = try lifecycleFixture(root: root, label: "content-evidence")
        let model = evidence.model
        try require(model.assessment(for: evidence.game).state == .partial,
                    "Fixture must expose a newer unselected local update")
        try require(model.transferredQueueShowsInstalled(),
                    "Selected installed update must confirm despite a newer unselected local update")
        model.inventory?.records.removeAll { $0.kind == .update }
        try require(!model.transferredQueueShowsInstalled(), "Missing selected update must block confirmation")
        model.inventory = evidence.inventory
        model.inventory?.records[1].rawVersion = 0
        try require(!model.transferredQueueShowsInstalled(), "Older installed selected update must block confirmation")
        model.inventory = evidence.inventory
        model.inventory?.isComplete = false
        try require(!model.transferredQueueShowsInstalled(), "Partial inventory must never confirm a whole batch")
        model.inventory = evidence.inventory
        model.inventorySessionSignature = nil
        try require(!model.transferredQueueShowsInstalled(), "Historical cached inventory must not confirm installation")
        model.inventorySessionSignature = "fixture-registry-A"
        model.installStatuses[0].state = .sending
        try require(!model.transferredQueueShowsInstalled(), "A still-sending file must not be confirmed")
        model.installStatuses[0].state = .transferred
        model.plan[0].target = .nand
        try require(!model.transferredQueueShowsInstalled(), "A request for another reviewed target must not confirm")
        model.plan[0].target = .sd
        model.plan[0].contents[0].byteCount += 1
        try require(!model.transferredQueueShowsInstalled(), "Changed source byte count must not confirm")
        print("PASS: selected content/version, coverage, session and reviewed-request evidence")

        let exclusive = try lifecycleFixture(root: root, label: "exclusive-verify")
        try require(!exclusive.model.canReadInventory, "Manual inventory control must be locked during verification")
        let manualRead = await exclusive.model.readInventory(timeoutSeconds: 1)
        await exclusive.model.refreshDevices()
        await exclusive.model.detectAndRead()
        try require(!manualRead, "Manual read must not join verification")
        try require(LifecycleChecks.probeCount(exclusive.probeMarker) == 0,
                    "Manual controls must not launch a competing inventory helper")
        let manualDiscoveryCount = await exclusive.discovery.calls
        try require(manualDiscoveryCount == 0, "Manual refresh must not race verification discovery")
        print("PASS: manual read/refresh exclusion during verification")

        let swapped = try lifecycleFixture(root: root, label: "swapped-device", devices: [LifecycleChecks.candidate("fixture-registry-B")])
        let swapResult = await swapped.model.confirmTransferredInstall(expectedSignature: "fixture-registry-A")
        try require(!swapResult, "A replacement USB registry entry cannot confirm the previous send")
        try require(LifecycleChecks.probeCount(swapped.probeMarker) == 0,
                    "Device swap must stop before any metadata helper opens")
        try require(swapped.model.inventorySessionSignature == nil && swapped.model.verificationDetail != nil,
                    "Swap must invalidate evidence and retain a visible reason")
        print("PASS: device swap stops before opening MTP")

        let fresh = try lifecycleFixture(root: root, label: "fresh-read")
        let freshResult = await fresh.model.confirmTransferredInstall(expectedSignature: "fixture-registry-A")
        try require(freshResult && LifecycleChecks.probeCount(fresh.probeMarker) == 1,
                    "Verification must accept one fresh, same-device libusb inventory")
        let finishing = Task { await fresh.model.finishInstallVerification(confirmed: freshResult) }
        try await Task.sleep(for: .milliseconds(100))
        try require(fresh.model.installListConfirmed && fresh.model.completedInstallGameIDs == [fresh.game.id],
                    "Confirmed success must mark only the selected game for exit")
        try require(fresh.model.plan.count == 2 && fresh.model.installationPlanLocked,
                    "Success must remain visible and plan locked before the exit delay")
        await finishing.value
        await fresh.model.planSaveTask?.value
        try require(fresh.model.plan.map(\.gameID) == ["fixture-unselected"],
                    "Confirmed row must leave the plan while unrelated unselected row remains")
        let saved = await fresh.model.planStore.loadPlan()
        try require(saved.items.map(\.gameID) == ["fixture-unselected"] && saved.error == nil,
                    "Confirmed row removal must persist to the isolated plan store")
        try require(!fresh.model.installationPlanLocked, "Plan unlocks only after confirmed removal")
        print("PASS: fresh read, visible success delay, selective removal and persistence")

        let unconfirmed = try lifecycleFixture(root: root, label: "unconfirmed")
        await unconfirmed.model.finishInstallVerification(confirmed: false)
        try require(unconfirmed.model.plan.count == 2 && unconfirmed.model.completedInstallGameIDs.isEmpty,
                    "Unconfirmed installation must retain every staged item")
        let cancelled = try lifecycleFixture(root: root, label: "cancel-after-confirm")
        let confirmedTask = Task { await cancelled.model.finishInstallVerification(confirmed: true) }
        try await Task.sleep(for: .milliseconds(100))
        confirmedTask.cancel()
        await confirmedTask.value
        await cancelled.model.planSaveTask?.value
        try require(cancelled.model.plan.map(\.gameID) == ["fixture-unselected"],
                    "Cancellation after reliable success cannot leave an installed row staged for resend")
        print("PASS: unconfirmed retention and cancellation after confirmation")

        let fenced = try lifecycleFixture(root: root, label: "worker-fence", errorCode: "workerExitUnverified")
        fenced.model.isVerifyingInstall = false
        try require(fenced.model.canBeginStagedInstallation, "Fixture installation must be eligible before the worker fence")
        fenced.model.isVerifyingInstall = true
        let fenceResult = await fenced.model.readInventory(forVerification: true, timeoutSeconds: 1)
        try require(!fenceResult && fenced.model.automaticReadBlocked,
                    "An unverified worker must establish the app-wide USB fence")
        fenced.model.isVerifyingInstall = false
        let retry = await fenced.model.readInventory(timeoutSeconds: 1)
        await fenced.model.detectAndRead()
        try require(!retry && LifecycleChecks.probeCount(fenced.probeMarker) == 1,
                    "No manual retry may spawn another process after unverified worker exit")
        try require(!fenced.model.canBeginStagedInstallation,
                    "Unverified inventory worker must also block installation")
        print("PASS: unverified worker blocks later reads and installation")
        print("PASS: \(LifecycleChecks.count) AppModel lifecycle assertions; fake processes and temporary files only")
    }
}

@main
private struct DeviceLifecycleRegression {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            guard CommandLine.arguments.count == 2 else {
                throw LifecycleFailure(description: "Expected isolated fixture directory")
            }
            let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try await AppModel.runDeviceLifecycleRegression(root: root)
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            Darwin.exit(1)
        }
    }
}
