# SwitchShelf implementation architecture

## Product and visual baseline
SwiftUI native macOS 26+, arm64, 03-liquid-glass.png is the selected visual reference. Sidebar and toolbar use native glass/material; content and inspector remain readable neutral surfaces. Main window 1280×820, minimum 960×640, adaptive inspector. Chinese interface, dark/light, keyboard and accessibility.

## Modules and ownership
- SwitchShelfDomain: value models, evidence-based installation assessment; coordinator owns public contract.
- SwitchShelfLibrary: actor-based read-only recursive SMB/local scanning, filename candidate parsing, source bookmarks, SQLite migrations and cache. agy owns implementation and library tests.
- SwitchShelfDevice + CDBIBridge: serialized USB discovery and read-only MTP inventory access; prioritize native ImageCaptureCore broker after successful hardware prototype, with optional libmtp fallback. pi owns implementation, probe executable and device tests.
- SwitchShelfApp: SwiftUI navigation, library grid/list/search/filter, inspector, device and queue pages, root observable app model; opencode owns UI.
- Coordinator: Package.swift, shared models, app composition, build/bundle scripts, integration, review and final tests.

## Stable interfaces for wave 1
Existing models in Sources/SwitchShelfDomain/Models.swift are the contract.
Library worker must expose:
```swift
public actor LibraryScanner: LibraryScanning {
    public init()
    public func scan(_ source: LibrarySource) async throws -> LibrarySnapshot
}
public actor LibraryRepository: LibraryPersisting {
    public init(databaseURL: URL) throws
    public func load() async throws -> LibrarySnapshot
    public func save(_ snapshot: LibrarySnapshot) async throws
}
```
Device worker must expose:
```swift
public actor DeviceService {
    public init()
    public func discover() async -> DeviceDiscovery
    public func readInventory() async throws -> InstalledInventory
}
```
UI should use these services directly via a MainActor app model; independent workers may compile against temporary local stubs while implementations arrive. Domain and Package.swift changes require coordinator.

## Evidence and boundaries
Current game source: /Volumes/switch 游戏包, SMB mounted NAS. No original-file writes. Store application state under Application Support/SwitchShelf, not NAS. Persist sources with security-scoped bookmarks when needed. Source disconnect retains previous entries and marks them offline; no wipe on failed enumeration. A complete inventory needs successful traversal of Installed games; missing storage or parse errors are not an empty list. MTP exposes virtual objects; do not download full NSPs for inventory. Device identity and environment remain session-scoped unless proven stable. Backend installation and MTP enumeration must never share the USB session concurrently.

SQLite is accessed through the system sqlite3 C interface in the initial dependency-free scaffold. This is a deliberate implementation choice replacing the document's candidate GRDB wrapper; keep schema migration boundaries so a wrapper can change later. Native ImageCaptureCore provides brokered PTP/MTP commands without competing with ptpcamerad for the USB interface. The coordinator verified open/GetStorageIDs/close against this Switch. If the optional libmtp route is retained, bundle its native dependencies; never require users to set up developer tooling in the final package.

## Scope gates
First integrated milestone: runnable native app, real NAS scan/cache, real device detection and read-only installed inventory, conservative installation badges and a persistent editable install plan. Installation execution is a separate next wave after protocol, result semantics and an explicit test file/target are established. Maintain the original development document's remaining metadata, installation, recovery and maintenance roadmap; an attractive shell alone does not complete that scope.

## Backend foundation wave — 2026-10-23

The user authorized supervised Orca agents to implement USB Backend software and hardware-free tests. `SwitchShelfBackend` owns transport-independent framing/session logic, allowlisted range reads, preparation checks and durable transfer state; `CDBIBackendUSB` owns the native USB adapter. The host protocol reference is pinned to rashevskyv/dbi `22090afc64cc7b5d645a99bf3d4d8625a67b766e` (`dbibackend`). No production UI or CLI may open a Backend transfer session in this wave. Native USB code is compiled and tested with fakes/argument checks only; actual installation requires a separately reviewed file/target test.

`BackendContracts.swift` is coordinator-owned for this wave. Protocol worker owns `SwitchShelfBackend/Protocol`; USB worker owns `CDBIBackendUSB` and `SwitchShelfBackend/USB`; UI/preflight worker owns `SwitchShelfApp` and `SwitchShelfBackend/Preflight`. A separate storage worker owns `SwitchShelfBackend/FileAccess`, `SwitchShelfBackend/Journal` and their tests. Coordinator owns the manifest, integration and final tests. Workers use separate child worktrees and must not launch further agents; the user's explicit delegation authorization applies to the coordinator.

Backend file exchange does not prove installation. Transfer outcomes are per file (`notRequested`, `partiallyTransferred`, `transferredAwaitingConfirmation`), and never promote a game to installed. SD/NAND selections remain local intent: the pinned host protocol does not encode a destination-setting command. Backend and MTP must not hold device sessions concurrently. No new source file reads, physical USB opens/writes, dependency installs or global settings changes are allowed in worker validation.


The user requested pi as the preferred development agent due to quota on 2026-10-23. The three initial Codex dispatches were explicitly stopped with their worktrees preserved. pi structured-session creation was refused by the current Orca runtime; use the documented existing-terminal supervision route if required. Agent identity and underlying model/provider are separate; do not claim a different quota pool without evidence.
