import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfDevice

private enum FixtureFailure: Error { case failed }
private actor FixtureTransport: InventoryTransport {
    let stores: [MTPStorage]
    let objects: [UInt32: MTPObject]
    let childLists: [UInt32: [UInt32]]
    let failedParents: Set<UInt32>
    let failedObjects: Set<UInt32>
    let failStorage: Bool
    var visitedParents: [UInt32] = []
    init(stores: [MTPStorage] = [MTPStorage(id: 4, name: "4: Installed games")],
         objects: [MTPObject] = [], children: [UInt32: [UInt32]] = [:],
         failedParents: Set<UInt32> = [], failedObjects: Set<UInt32> = [], failStorage: Bool = false) {
        self.stores = stores; self.objects = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        self.childLists = children; self.failedParents = failedParents
        self.failedObjects = failedObjects; self.failStorage = failStorage
    }
    func storages() throws -> [MTPStorage] { if failStorage { throw FixtureFailure.failed }; return stores }
    func children(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        visitedParents.append(parent)
        if failedParents.contains(parent) { throw FixtureFailure.failed }
        return childLists[parent] ?? []
    }
    func object(id: UInt32) throws -> MTPObject {
        guard !failedObjects.contains(id), let value = objects[id] else { throw FixtureFailure.failed }
        return value
    }
    func close() {}
}
actor CancellingTransport: InventoryTransport {
    enum Stage { case storages, children, object }
    let stage: Stage
    init(_ stage: Stage) { self.stage = stage }
    func storages() -> [MTPStorage] {
        if stage == .storages { withUnsafeCurrentTask { $0?.cancel() } }
        return [MTPStorage(id: 4, name: "4: Installed games")]
    }
    func children(storage: UInt32, parent: UInt32) -> [UInt32] {
        if stage == .children { withUnsafeCurrentTask { $0?.cancel() } }
        return [1]
    }
    func object(id: UInt32) -> MTPObject {
        if stage == .object { withUnsafeCurrentTask { $0?.cancel() } }
        return MTPObject(id: 1, parentID: 0, storageID: 4, name: "Fixture [0100000000001000][v0][BASE].nsp", isFolder: false)
    }
    func close() {}
}
private let root = UInt32.max
private func folder(_ id: UInt32, parent: UInt32 = 0, name: String = "Fixture game") -> MTPObject {
    MTPObject(id: id, parentID: parent, storageID: 4, name: name, isFolder: true)
}
private func file(_ id: UInt32, parent: UInt32 = 1,
                  name: String = "Fixture [0100000000001000][v0][BASE].nsp") -> MTPObject {
    MTPObject(id: id, parentID: parent, storageID: 4, name: name, isFolder: false)
}

@Suite("Device discovery: descriptors are candidates, never readiness")
struct DiscoveryTests {
    @Test func correctPairsOnly() {
        let inputs = [USBDescriptor(vendorID: 0x057e, productID: 0x201d),
                      USBDescriptor(vendorID: 0x057e, productID: 0x3000),
                      USBDescriptor(vendorID: 0x057e, productID: 0x2000),
                      USBDescriptor(vendorID: 0x057e, productID: 0x2009),
                      USBDescriptor(vendorID: 0x1234, productID: 0x201d)]
        let discovery = DiscoveryClassifier.classify(inputs)
        #expect(discovery.devices.map(\.productID) == [0x201d, 0x3000, 0x2000])
        #expect(discovery.state == .detected)
    }
    @Test func mtpPairDoesNotProveReady() {
        let discovery = DiscoveryClassifier.classify([USBDescriptor(vendorID: 0x057e, productID: 0x201d)])
        #expect(discovery.state == .waitingForMTP)
        #expect(!discovery.message.isEmpty)
    }
    @Test func observedNormalSwitchDescriptorDoesNotMeanDisconnectedOrReady() {
        let discovery = DiscoveryClassifier.classify([USBDescriptor(vendorID: 0x057e, productID: 0x2000)])
        #expect(discovery.state == .waitingForMTP)
        #expect(discovery.devices.count == 1)
        #expect(!discovery.devices[0].name.contains("DBI"))
        #expect(discovery.message.contains("未确认"))
    }
    @Test func vendorAloneAndControllersAreIgnored() {
        #expect(DiscoveryClassifier.classify([USBDescriptor(vendorID: 0x057e, productID: 0x2009)]).state == .disconnected)
    }
    @Test func discoveryIdentityIsObservationScoped() {
        let input = [USBDescriptor(vendorID: 0x057e, productID: 0x201d)]
        #expect(DiscoveryClassifier.classify(input).devices[0].id != DiscoveryClassifier.classify(input).devices[0].id)
    }
}

@Suite("Conservative object identity parsing")
struct IdentityTests {
    @Test func explicitMetadataTokens() {
        let parsed = InstalledObjectParser.parse("Anything [0100abcdef123000][v65536][UPD].nsp")
        #expect(parsed.titleID == "0100ABCDEF123000")
        #expect(parsed.rawVersion == 65536)
        #expect(parsed.kind == .update)
        #expect(parsed.issues.isEmpty)
    }
    @Test func explicitHexRawVersionAndDLC() {
        let parsed = InstalledObjectParser.parse("X [titleid=0100ABCDEF123001][version=0x20000][DLC].nsp")
        #expect(parsed.rawVersion == 131072)
        #expect(parsed.kind == .dlc)
        #expect(parsed.issues.isEmpty)
    }
    @Test func displayNamesAndVersionsAreNotIdentity() {
        let parsed = InstalledObjectParser.parse("Game Update 0100ABCDEF123000 v1.2.3.nsp")
        #expect(parsed.titleID == nil)
        #expect(parsed.rawVersion == nil)
        #expect(parsed.kind == .unknown)
        #expect(!parsed.issues.isEmpty)
    }
    @Test func idArithmeticDoesNotInventKind() {
        let parsed = InstalledObjectParser.parse("X [0100ABCDEF123800][v65536].nsp")
        #expect(parsed.titleID != nil)
        #expect(parsed.kind == .unknown)
        #expect(!parsed.issues.isEmpty)
    }
    @Test func combinedAndConflictingTokensAreAmbiguous() {
        let parsed = InstalledObjectParser.parse("X [0100000000001000][0100000000001800][v0][v65536][BASE][UPD].nsp")
        #expect(parsed.titleID == nil)
        #expect(parsed.rawVersion == nil)
        #expect(parsed.kind == .unknown)
    }
    @Test func rawVersionOverflowNeverWraps() {
        let parsed = InstalledObjectParser.parse("X [0100000000001000][v4294967296][BASE].nsp")
        #expect(parsed.rawVersion == nil)
        #expect(!parsed.issues.isEmpty)
    }
    @Test func malformedExplicitIDCannotBeHiddenByValidToken() {
        let parsed = InstalledObjectParser.parse("X [0100000000001000][titleid=bad][v0][BASE].nsp")
        #expect(parsed.titleID == nil)
        #expect(!parsed.issues.isEmpty)
    }
    @Test func repeatedSameTokenIsNotConflict() {
        #expect(InstalledObjectParser.parse("X [0100000000001000][v0][v0][BASE].nsp").issues.isEmpty)
    }
}

@Suite("Read-only inventory coverage semantics")
struct InventoryTests {
    @Test func missingStorageIsNotEmptyCompleteInventory() async throws {
        let transport = FixtureTransport(stores: [MTPStorage(id: 1, name: "SD Card")])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
        #expect(result.issues.contains { $0.contains("Installed games") })
        #expect(result.issues.contains { $0.contains("SD Card") })
        #expect(await transport.visitedParents.isEmpty)
    }
    @Test func storageNamesRequireExactKnownEntry() {
        #expect(InventoryReader.isInstalledGames("4: Installed games"))
        #expect(InventoryReader.isInstalledGames("Installed games"))
        #expect(!InventoryReader.isInstalledGames("Backup Installed games"))
        #expect(!InventoryReader.isInstalledGames("5: SD Card install"))
        // Observed on DBI 647-zhcn: a separate SD storage, not installed-content evidence.
        #expect(!InventoryReader.isInstalledGames("1: SD内存卡"))
    }
    @Test func observedLocalizedSDStorageAloneIsNotEmptyInstalledInventory() async throws {
        let transport = FixtureTransport(stores: [MTPStorage(id: 1, name: "1: SD内存卡")])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
        #expect(result.issues.contains { $0.contains("1: SD内存卡") })
        #expect(await transport.visitedParents.isEmpty)
    }
    @Test func unrecognizedStorageDiagnosticsAreEscapedAndBounded() async throws {
        // Synthetic descriptions exercise diagnostic limits, not DBI naming rules.
        let stores = [MTPStorage(id: 1, name: "Fixture\n\"quoted\""),
                      MTPStorage(id: 2, name: String(repeating: "名", count: 10_000))]
            + (3...100).map { MTPStorage(id: UInt32($0), name: "Fixture storage \($0)") }
        let transport = FixtureTransport(stores: stores)
        let result = try await InventoryReader().read(from: transport)
        let diagnostic = try #require(result.issues.last)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
        #expect(diagnostic.contains("Fixture\\n\\\"quoted\\\""))
        #expect(!diagnostic.contains("\n"))
        #expect(diagnostic.contains("100 项"))
        #expect(!diagnostic.contains("Fixture storage 100"))
        #expect(diagnostic.utf8.count < 12_000)
        #expect(await transport.visitedParents.isEmpty)
    }
    @Test func verifiedEmptyTraversalCanBeComplete() async throws {
        let result = try await InventoryReader().read(from: FixtureTransport())
        #expect(result.isComplete)
        #expect(result.records.isEmpty)
        #expect(result.environmentContext == nil)
    }
    @Test func storageDiagnosticsNeverTraverseEvenRecognizedInstalledStorage() async throws {
        let transport = FixtureTransport(stores: [MTPStorage(id: 4, name: "4: Installed games"),
                                                   MTPStorage(id: 1, name: "1: SD内存卡")],
                                         objects: [folder(1), file(2)], children: [root: [1], 1: [2]])
        let result = try await InventoryReader().read(from: transport, storageDiagnosticsOnly: true)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
        #expect(result.environmentContext == nil)
        #expect(result.issues.contains { $0.contains("未遍历任何内容对象") })
        #expect(result.issues.contains { $0.contains("4: Installed games") && $0.contains("1: SD内存卡") })
        #expect(await transport.visitedParents.isEmpty)
    }
    @Test(arguments: [CancellingTransport.Stage.storages, .children, .object])
    func cancellationAfterMetadataAwaitNeverReturnsInventory(_ stage: CancellingTransport.Stage) async {
        let read = Task { try await InventoryReader().read(from: CancellingTransport(stage)) }
        await #expect(throws: CancellationError.self) { try await read.value }
    }
    @Test func storageFailureThrowsInsteadOfClaimingEmpty() async {
        await #expect(throws: FixtureFailure.self) {
            try await InventoryReader().read(from: FixtureTransport(failStorage: true))
        }
    }
    @Test func nestedBaseUpdateDLCAndDuplicateProjection() async throws {
        let objects = [folder(1), folder(2, parent: 1, name: "Components"), file(3, parent: 2),
            file(4, parent: 2, name: "X [0100000000001800][v65536][UPD].nsp"),
            file(5, parent: 2, name: "X [0100000000001001][v0][DLC].nsp"), file(6, parent: 2)]
        let transport = FixtureTransport(objects: objects, children: [root: [1], 1: [2], 2: [3, 4, 5, 6]])
        let result = try await InventoryReader().read(from: transport)
        #expect(result.isComplete)
        #expect(result.records.count == 3)
        #expect(Set(result.records.map(\.kind)) == [.base, .update, .dlc])
        #expect(result.records.allSatisfy { $0.objectPath.contains("/Components/") })
    }
    @Test func eachReadHasNewSessionAndUnknownEnvironment() async throws {
        let reader = InventoryReader()
        let first = try await reader.read(from: FixtureTransport())
        let second = try await reader.read(from: FixtureTransport())
        #expect(first.deviceID != second.deviceID)
        #expect(first.environmentContext == nil)
    }
    @Test func failedFolderRetainsPartialRecords() async throws {
        let transport = FixtureTransport(objects: [folder(1), folder(2), file(3)],
            children: [root: [1, 2], 1: [3]], failedParents: [2])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.count == 1)
        #expect(!result.issues.isEmpty)
    }
    @Test func omittedMetadataCannotBecomeComplete() async throws {
        let transport = FixtureTransport(objects: [folder(1), file(2)], children: [root: [1], 1: [2, 3]], failedObjects: [3])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.count == 1)
    }
    @Test func parseFailureDoesNotInheritParentIdentity() async throws {
        let transport = FixtureTransport(objects: [folder(1, name: "X [0100000000001000]"), file(2, name: "Unknown DLC.nsp")],
                                         children: [root: [1], 1: [2]])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.count == 1)
        #expect(result.records[0].titleID == nil)
    }
    @Test func rootCombinedPackageIsNotOneContent() async throws {
        let result = try await InventoryReader().read(from: FixtureTransport(objects: [file(1, parent: 0)], children: [root: [1]]))
        #expect(!result.isComplete)
        #expect(result.records.isEmpty) // Combined projection is not double-counted as one content.
    }
    @Test func explicitRedundantCombinedRootCanBeResolvedAfterCompleteNestedTraversal() async throws {
        let objects = [folder(1, name: "Game [0100000000001000]"), file(2),
            file(3, name: "X [0100000000001800][v65536][UPD].nsp"),
            file(4, name: "X [0100000000001001][v0][DLC].nsp"),
            file(9, parent: 0, name: "Combined [0100000000001000][v65536].nsp")]
        let transport = FixtureTransport(objects: objects, children: [root: [9, 1], 1: [2, 3, 4]])
        let result = try await InventoryReader().read(from: transport)
        #expect(result.isComplete)
        #expect(result.records.count == 3)
        #expect(result.issues.isEmpty)
    }
    @Test func unattributedRootWithOtherwiseCompleteNestedRecordsRemainsPartial() async throws {
        let objects = [folder(1, name: "Game [0100000000001000]"), file(2),
                       file(9, parent: 0, name: "Combined unknown.nsp")]
        let result = try await InventoryReader().read(from: FixtureTransport(objects: objects,
            children: [root: [1, 9], 1: [2]]))
        #expect(!result.isComplete)
        #expect(result.records.count == 1)
    }
    @Test func rootCannotAssociateByDisplayName() async throws {
        let objects = [folder(1, name: "Same display name"), file(2),
            file(9, parent: 0, name: "Same display name [0100000000001000].nsp")]
        let result = try await InventoryReader().read(from: FixtureTransport(objects: objects,
            children: [root: [1, 9], 1: [2]]))
        #expect(!result.isComplete)
        #expect(result.records.count == 1)
    }
    @Test func rootFolderIDWithoutNestedBaseEvidenceRemainsPartial() async throws {
        let objects = [folder(1, name: "Game [0100000000001000]"),
            file(2, name: "X [0100000000001800][v65536][UPD].nsp"),
            file(9, parent: 0, name: "Combined [0100000000001000].nsp")]
        let result = try await InventoryReader().read(from: FixtureTransport(objects: objects,
            children: [root: [1, 9], 1: [2]]))
        #expect(!result.isComplete)
        #expect(result.records.count == 1)
    }
    @Test func repeatedCycleAndWrongParentAreIncomplete() async throws {
        let transport = FixtureTransport(objects: [folder(1), file(2, parent: 999)], children: [root: [1], 1: [1, 2]])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
    }
    @Test func modsRedirectIsNotTraversed() async throws {
        let transport = FixtureTransport(objects: [folder(1, name: "Mods & Cheats")], children: [root: [1]])
        let result = try await InventoryReader().read(from: transport)
        #expect(result.isComplete)
        #expect(await transport.visitedParents == [root])
    }
    @Test func gameFolderWithOnlyModsCannotProveEmpty() async throws {
        let transport = FixtureTransport(objects: [folder(1), folder(2, parent: 1, name: "Mods & Cheats")],
                                         children: [root: [1], 1: [2]])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
    }
    @Test func emptyGameFolderIsUnverifiable() async throws {
        let result = try await InventoryReader().read(from: FixtureTransport(objects: [folder(1)], children: [root: [1]]))
        #expect(!result.isComplete)
    }
    @Test func depthObjectAndTimeBudgetsNeverClaimComplete() async throws {
        let transport = FixtureTransport(objects: [folder(1), file(2)], children: [root: [1], 1: [2]])
        #expect(!(try await InventoryReader(maximumObjects: 1).read(from: transport)).isComplete)
        #expect(!(try await InventoryReader(maximumDepth: 0).read(from: transport)).isComplete)
        #expect(!(try await InventoryReader(budget: .zero).read(from: transport)).isComplete)
    }
    @Test func nativeErrorTextNeverLeaksIntoIssues() async throws {
        let result = try await InventoryReader().read(from: FixtureTransport(failedParents: [root]))
        #expect(!result.isComplete)
        #expect(result.issues.allSatisfy { !$0.contains("FixtureFailure") })
    }
    @Test func missingRuntimeIsActionableAndReleasesGateWithoutUSB() throws {
        for _ in 0..<2 {
            do {
                _ = try NativeMTPSession(runtimePath: "/SwitchShelf-fixture/nonexistent/libmtp.9.dylib")
                Issue.record("Missing runtime unexpectedly opened")
            } catch let error as DeviceServiceError {
                #expect(error.code == .runtimeMissing)
                #expect(error.message.contains("SWITCHSHELF_LIBMTP_PATH"))
            }
        }
    }
}

private func ptpString(_ value: String) -> Data {
    var data = Data([UInt8(value.utf16.count + 1)])
    for unit in value.utf16 { PTPCodec.append(unit, to: &data) }
    PTPCodec.append(UInt16(0), to: &data)
    return data
}
private func response(_ code: UInt16 = 0x2001, transaction: UInt32 = 500) -> Data {
    var data = Data(); PTPCodec.append(UInt32(12), to: &data)
    PTPCodec.append(UInt16(3), to: &data); PTPCodec.append(code, to: &data)
    PTPCodec.append(transaction, to: &data); return data
}
@Suite("Strict metadata-only PTP codec")
struct PTPTests {
    @Test func commandAllowlistRejectsMutationAndDownloads() throws {
        for operation: UInt16 in [0x1009, 0x100a, 0x100b, 0x100c, 0x100d, 0x100f, 0x1010] {
            #expect(throws: DeviceServiceError.self) { try PTPCodec.command(operation, parameters: [], transaction: 1) }
        }
        #expect(try PTPCodec.command(0x1007, parameters: [4, 0, root], transaction: 1).count == 24)
    }
    @Test func responseMustBeSuccessAndWellFormedButBrokerCanReassignTransaction() throws {
        try PTPCodec.validateResponse(response(transaction: 9999))
        #expect(throws: DeviceServiceError.self) { try PTPCodec.validateResponse(response(0x2019)) }
        #expect(throws: DeviceServiceError.self) { try PTPCodec.validateResponse(Data(response().prefix(8))) }
        var malformed = response(); malformed[4] = 1
        #expect(throws: DeviceServiceError.self) { try PTPCodec.validateResponse(malformed) }
    }
    @Test func handleCountsMustMatchExactly() throws {
        var data = Data(); PTPCodec.append(UInt32(2), to: &data)
        PTPCodec.append(UInt32(1), to: &data); PTPCodec.append(UInt32(2), to: &data)
        #expect(try PTPCodec.identifiers(data) == [1, 2])
        #expect(throws: DeviceServiceError.self) { try PTPCodec.identifiers(Data(data.dropLast())) }
        #expect(throws: DeviceServiceError.self) { try PTPCodec.identifiers(Data([255, 255, 255, 255])) }
    }
    @Test func storageDatasetDecodesWithoutRetainingVolumeIdentity() throws {
        var data = Data(repeating: 0, count: 26)
        data.append(ptpString("4: Installed games")); data.append(ptpString("PRIVATE-VOLUME-ID"))
        #expect(try PTPCodec.storage(data, id: 4) == MTPStorage(id: 4, name: "4: Installed games"))
        #expect(throws: DeviceServiceError.self) { try PTPCodec.storage(Data(data.dropLast()), id: 4) }
    }
    @Test func objectDatasetUsesCorrectOffsetsAndUTF16() throws {
        var data = Data(repeating: 0, count: 52)
        data[0] = 4; data[4] = 1; data[5] = 0x30; data[38] = 7
        data.append(ptpString("测试 🐬")); data.append(contentsOf: [0, 0, 0])
        let object = try PTPCodec.object(data, id: 8)
        #expect(object.storageID == 4)
        #expect(object.parentID == 7)
        #expect(object.name == "测试 🐬")
        #expect(object.isFolder)
        #expect(throws: DeviceServiceError.self) { try PTPCodec.object(Data(data.prefix(53)), id: 8) }
    }
    @Test func malformedStringsAndTrailingBytesFailClosed() throws {
        var data = Data(repeating: 0, count: 26)
        data.append(contentsOf: [1, 65, 0, 0]) // Nonzero string terminator.
        #expect(throws: DeviceServiceError.self) { try PTPCodec.storage(data, id: 4) }
        var other = Data(repeating: 0, count: 26)
        other.append(ptpString("Installed games")); other.append(contentsOf: [0, 99])
        #expect(throws: DeviceServiceError.self) { try PTPCodec.storage(other, id: 4) }
    }
}
