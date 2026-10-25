import Foundation
import Testing
import SwitchShelfDomain
@testable import SwitchShelfDevice

private let sphairaRoot = UInt32.max

private actor SphairaFixture: InventoryTransport {
    // Storage/filename descriptions observed through OpenMTP on 2026-10-25.
    // Handles are synthetic; they are never persistent console identities.
    static let stores = ["DevNull (Speed Test)", "Mounts", "Install (NSP, XCI, NSZ, XCZ, MSP)",
                         "Games", "Contents (User)", "Contents (System)", "Contents (microSD card)",
                         "Album (Image SD)", "microSD card"].enumerated().map {
        MTPStorage(id: UInt32($0.offset + 1), name: $0.element)
    }
    static let samples = [
        MTPObject(id: 100, parentID: 0, storageID: 4, name: "1-2-Switch [01000320000CC000]", isFolder: true),
        MTPObject(id: 101, parentID: 100, storageID: 4, name: "1-2-Switch [01000320000CC000][v0][BASE].nsp", isFolder: false),
        MTPObject(id: 102, parentID: 100, storageID: 4, name: "1-2-Switch 1.1.0 [01000320000CC800][v65536][UPD].nsp", isFolder: false),
        MTPObject(id: 200, parentID: 0, storageID: 4, name: "The Legend of Zelda_ Breath of the Wild [01007EF00011E000]", isFolder: true),
        MTPObject(id: 201, parentID: 200, storageID: 4, name: "The Legend of Zelda_ Breath of the Wild [01007EF00011E000][v0][BASE].nsp", isFolder: false),
        MTPObject(id: 202, parentID: 200, storageID: 4, name: "The Legend of Zelda_ Breath of the Wild 1.6.0 [01007EF00011E800][v786432][UPD].nsp", isFolder: false),
        MTPObject(id: 203, parentID: 200, storageID: 4, name: "The Legend of Zelda_ Breath of the Wild [01007EF00011F001][v196608][DLC].nsp", isFolder: false),
        MTPObject(id: 204, parentID: 200, storageID: 4, name: "The Legend of Zelda_ Breath of the Wild [01007EF00011F002][v196608][DLC].nsp", isFolder: false)
    ]
    let storageList: [MTPStorage]
    let objects: [UInt32: MTPObject]
    let lists: [UInt32: [UInt32]]
    var visitedStorageIDs: [UInt32] = []
    init(storages: [MTPStorage] = stores, objects: [MTPObject] = samples,
         children: [UInt32: [UInt32]] = [sphairaRoot: [100, 200], 100: [101, 102], 200: [201, 202, 203, 204]]) {
        storageList = storages
        self.objects = Dictionary(uniqueKeysWithValues: objects.map { ($0.id, $0) })
        lists = children
    }
    func storages() -> [MTPStorage] { storageList }
    func children(storage: UInt32, parent: UInt32) -> [UInt32] {
        visitedStorageIDs.append(storage)
        return lists[parent] ?? []
    }
    func object(id: UInt32) throws -> MTPObject {
        guard let value = objects[id] else { throw CocoaError(.fileNoSuchFile) }
        return value
    }
    func close() {}
}

@Suite("Observed sphaira Games projection")
struct SphairaInventoryTests {
    @Test func observedBaseUpdateAndDLCMetadataIsReadableWithoutPackageBytes() async throws {
        let transport = SphairaFixture()
        let result = try await InventoryReader().read(from: transport)
        #expect(result.isComplete)
        #expect(result.issues.isEmpty)
        #expect(result.records.count == 6)
        #expect(result.records.filter { $0.kind == .base }.count == 2)
        #expect(result.records.filter { $0.kind == .update }.map(\.rawVersion).sorted { ($0 ?? 0) < ($1 ?? 0) } == [65536, 786432])
        #expect(result.records.filter { $0.kind == .dlc }.map(\.titleID).compactMap { $0 }.sorted() == ["01007EF00011F001", "01007EF00011F002"])
        #expect(result.environmentContext == nil)
        #expect(result.mtpEvidence?.reportedStorageCount == 9)
        #expect(result.mtpEvidence?.inventoryStorageNames == ["Games"])
        #expect(result.mtpEvidence?.gameDirectoryCount == 2)
        #expect(result.mtpEvidence?.metadataObjectCount == 8)
        #expect(Set(await transport.visitedStorageIDs) == [4])
    }

    @Test func sphairaVirtualObjectStorageAndRootParentAreScopedToGames() async throws {
        // A live sphaira metadata-only probe reported Games storage 0xFFFFFFF9,
        // root-object parent 0xFFFFFFF9 and object storage 0xFFFFFFFE.
        let objects = SphairaFixture.samples.map { object in
            MTPObject(id: object.id, parentID: object.parentID == 0 ? 4 : object.parentID,
                      storageID: UInt32.max - 1, name: object.name, isFolder: object.isFolder)
        }
        let games = try await InventoryReader().read(from: SphairaFixture(objects: objects))
        #expect(games.isComplete)
        #expect(games.records.count == 6)
        let dbi = try await InventoryReader().read(from: SphairaFixture(
            storages: [MTPStorage(id: 4, name: "Installed games")], objects: objects))
        #expect(!dbi.isComplete)
        #expect(dbi.records.isEmpty)
    }

    @Test func sphairaVirtualObjectStillRequiresMatchingGamesParent() async throws {
        let object = MTPObject(id: 100, parentID: 3, storageID: UInt32.max - 1,
                               name: SphairaFixture.samples[0].name, isFolder: true)
        let result = try await InventoryReader().read(from: SphairaFixture(
            objects: [object], children: [sphairaRoot: [100]]))
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
    }

    @Test func onlyExactGamesStorageIsRecognized() {
        #expect(InventoryReader.isInstalledGames("Games"))
        #expect(InventoryReader.isInstalledGames(" games \n"))
        for name in ["My Games", "Games backup", "Installed", "Contents (User)", "Mounts", "Install (NSP, XCI, NSZ, XCZ, MSP)"] {
            #expect(!InventoryReader.isInstalledGames(name))
        }
    }

    @Test func otherEnabledSphairaStoragesAreNeverTraversed() async throws {
        let transport = SphairaFixture(storages: SphairaFixture.stores.filter { $0.name != "Games" })
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
        #expect(result.mtpEvidence?.reportedStorageCount == 8)
        #expect(result.mtpEvidence?.inventoryStorageNames.isEmpty == true)
        #expect(await transport.visitedStorageIDs.isEmpty)
    }

    @Test func ordinarySDFolderNamedGamesDoesNotBecomeInstalledEvidence() async throws {
        let transport = SphairaFixture(storages: [MTPStorage(id: 4, name: "microSD card")])
        let result = try await InventoryReader().read(from: transport)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
        #expect(await transport.visitedStorageIDs.isEmpty)
    }

    @Test func storageDiagnosticsKeepConnectionEvidenceWithoutTraversingGames() async throws {
        let transport = SphairaFixture()
        let result = try await InventoryReader().read(from: transport, storageDiagnosticsOnly: true)
        #expect(!result.isComplete)
        #expect(result.records.isEmpty)
        #expect(result.mtpEvidence?.storageDiagnosticsOnly == true)
        #expect(result.mtpEvidence?.inventoryStorageNames == ["Games"])
        #expect(result.mtpEvidence?.metadataObjectCount == 0)
        #expect(await transport.visitedStorageIDs.isEmpty)
    }

    @Test func unsupportedGameMetadataNeverInheritsDirectoryIdentity() async throws {
        let objects = [SphairaFixture.samples[0], MTPObject(id: 101, parentID: 100, storageID: 4, name: "Unknown DLC.nsp", isFolder: false)]
        let result = try await InventoryReader().read(from: SphairaFixture(objects: objects, children: [sphairaRoot: [100], 100: [101]]))
        #expect(!result.isComplete)
        #expect(result.records.count == 1)
        #expect(result.records.first?.titleID == nil)
        #expect(result.records.first?.kind == .unknown)
    }

    @Test func interruptedGamesTraversalRetainsOnlyPartialEvidence() async throws {
        let result = try await InventoryReader(maximumObjects: 2).read(from: SphairaFixture())
        #expect(!result.isComplete)
        #expect(result.mtpEvidence?.inventoryStorageNames == ["Games"])
    }

    @Test func structuredEvidenceIsBounded() async throws {
        let stores = (1...100).map { MTPStorage(id: UInt32($0), name: String(repeating: "名", count: 300)) }
        let result = try await InventoryReader().read(from: SphairaFixture(storages: stores))
        #expect(result.mtpEvidence?.reportedStorageCount == 100)
        #expect(result.mtpEvidence?.reportedStorageNames.count == 32)
        #expect(result.mtpEvidence?.reportedStorageNames.allSatisfy { $0.count <= 128 } == true)
    }

    @Test func oldHelperInventoryJSONStillDecodesWithoutEvidence() throws {
        let original = InstalledInventory(deviceID: "legacy-session", isComplete: false)
        let data = try JSONEncoder().encode(original)
        let result = try JSONDecoder().decode(InstalledInventory.self, from: data)
        #expect(result == original)
        #expect(result.mtpEvidence == nil)
    }

    @Test func evidenceSurvivesHelperJSONRoundTrip() async throws {
        let original = try await InventoryReader().read(from: SphairaFixture())
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(InstalledInventory.self, from: data) == original)
    }
}
