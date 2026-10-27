# SwitchShelf implementation architecture

## Product and visual baseline
SwiftUI native macOS 26+, arm64, 03-liquid-glass.png is the selected visual reference. Sidebar and toolbar use native glass/material; content and inspector remain readable neutral surfaces. Main window 1280×820, minimum 960×640, adaptive inspector. Chinese interface, dark/light, keyboard and accessibility.

## Modules and ownership
- SwitchShelfDomain: value models, evidence-based installation assessment; coordinator owns public contract.
- SwitchShelfLibrary: actor-based read-only recursive SMB/local scanning, filename candidate parsing, source bookmarks, SQLite migrations and cache. agy owns implementation and library tests.
- SwitchShelfDevice + CDBIBridge: serialized USB discovery and read-only MTP inventory access for sphaira `Games` and DBI `Installed games`; native ImageCaptureCore broker with optional libmtp fallback. Also owns sphaira-specific local installation preflight, bounded native libusb MTP streaming and the isolated, explicitly confirmed single-file installation test flow. Physical installation is not yet accepted. pi owns the original module; this follow-up is coordinator-owned integration.
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
Current game source: /Volumes/switch 游戏包, SMB mounted NAS. No original-file writes. Store application state under Application Support/SwitchShelf, not NAS. Persist sources with security-scoped bookmarks when needed. Source disconnect retains previous entries and marks them offline; no wipe on failed enumeration. A complete inventory needs successful traversal of a recognized installed-content projection; missing storage or parse errors are not an empty list. MTP exposes virtual objects; do not download full NSPs for inventory. Device identity and environment remain session-scoped unless proven stable. Backend installation and MTP enumeration must never share the USB session concurrently.

SQLite is accessed through the system sqlite3 C interface in the initial dependency-free scaffold. This is a deliberate implementation choice replacing the document's candidate GRDB wrapper; keep schema migration boundaries so a wrapper can change later. Native ImageCaptureCore provides brokered PTP/MTP commands without competing with ptpcamerad for the USB interface. The coordinator verified open/GetStorageIDs/close against this Switch. If the optional libmtp route is retained, bundle its native dependencies; never require users to set up developer tooling in the final package.

## MTP integration follow-up — 2026-10-25

- Recognized storage descriptions are exactly `Games` (observed sphaira layout), `Installed games` and `4: Installed games` (DBI layout), ignoring case/outer whitespace. A folder named Games on an ordinary SD storage is not a source. Raw Contents, Mounts, saves, installation and DevNull are catalogued by name only, never traversed by the inventory reader.
- Nested per-content objects must provide explicit Title ID, raw version and BASE/UPD/DLC tokens. Existing coverage, cancellation, depth/object/time limits and combined-projection checks also apply to Games. No human-title or parent-ID inference is introduced. A live read established that sphaira Games object info uses virtual storage `0xFFFFFFFE` and the Games storage handle as top-level parent; accept that alias only within the exact Games storage, retaining strict parent checks and strict DBI/SD behavior.
- `InstalledInventory.mtpEvidence` is an optional coordinator-owned additive contract: bounded storage descriptions, selected sources, observed game-directory/metadata-object counts and storage-only mode. Older helper JSON still decodes; helper schema remains 1. Storage labels describe capabilities, not a verified server version. Storage capacities are not used as installation evidence or console capacity.
- USB candidate detection, successful MTP communication and inventory completeness are separate. A successful catalog with no game source is connected but incomplete. Rediscovery invalidates the previous inventory even if VID/PID match. The app asks the user to quit a running OpenMTP before its own inventory request; this preflight does not claim the process necessarily owns an interface. The advisory lease only coordinates SwitchShelf participants.
- ImageCaptureCore remains the default. Its ptpcamerad broker is not killed or disabled; the OpenMTP/Preview conflict observed in troubleshooting is not a system-service workaround.

## Scope gates
First integrated milestone: runnable native app, real NAS scan/cache, real device detection and read-only installed inventory, conservative installation badges and a persistent editable install plan. Installation execution is a separate next wave after protocol, result semantics and an explicit test file/target are established. Maintain the original development document's remaining metadata, installation, recovery and maintenance roadmap; an attractive shell alone does not complete that scope.

## sphaira MTP installation direction — 2026-10-25

The user selected sphaira MTP for both inventory and future installation; Backend is deferred, not removed. The app's local preparation now uses `SphairaInstallPreflight`, without importing Backend. Package.swift and existing uncommitted Backend work were preserved. The initial disabled foundation was followed by the user-requested 0.3.0 native single-file **test** package; the confirmation flow is enabled, not claimed as production hardware acceptance.

- Source baseline: sphaira `338348e74b6d278bc570a9be5373d25197bf6c8d`, which pins R-YaTian/libhaze `f1c9c632b5c615eabfb29a0dab89fedf606588e4`. These are reviewed upstream sources, NOT identification of the connected device's build. Install storage visibility alone does not mean installation mode is active: the user must enter **MTP Install**. Destination is chosen inside sphaira; local SD/NAND intent is not a host command.
- `SphairaUploadCodec` is separate from the inventory codec. The internal sender uses `SendObjectPropList` (`0x9808`, 64-bit size and filename property) then one streaming `SendObject` (`0x100d`). It never seeks, sends partial-object edits, deletes objects, formats, retries or resumes. All game records/badges remain governed by independent inventory evidence.
- The sender requires same-session sphaira device-description/capability evidence and an unambiguous exact Install storage plus Games; numeric storage handles are never persisted. Its final success state means **transferredAwaitingConfirmation**, not installed. Lost acknowledgment, cancellation, source change and transport failure after the first write leave device state unknown. A failed release is explicit.
- `SphairaPackageSource` pins a read-only descriptor under an explicit source root, rejects symlinks in every component, checks inode/size/mtime/ctime and uses bounded positional reads. Preflight only inspects metadata and is not authorization. Its result must not replace execution-time source validation or reviewed file/target consent.
- `NativeSphairaMTP` uses a separate explicit-open libusb adapter, not ImageCaptureCore outData. Output header/payload are coalesced into packet-aligned bounded writes; only the final short packet or ZLP terminates the data phase. DeviceInfo, operations and storage descriptions are inspected within the same opened PTP session. There is no driver detach, reset, configuration change, fallback destination or automatic retry. Required libusb and its license ship inside the app.
- `SphairaInstaller` supervises one direct token-gated `switchshelf-probe` child; the child takes DeviceLease before physical open, validates the reviewed source fingerprint and durably records side-effect intent before sending. Parent verifies the child's actual exit after cancellation/deadline escalation; uncertain exit fences subsequent requests. A bounded progress-delivery relay cannot block the deadline loop. The child also stops if its original parent exits. An app crash leaves the attempt record unknown, not resumable or installed.
- UI execution is explicitly experimental and requires exactly one selected file, a current passing preflight, a metadata-pinned review, and four user confirmations of file authority/device mode/target/exclusivity/risk before any helper launch. Queue editing and inventory reads are blocked while sending. Raw USB access may still fail if the system broker or another client owns the interface; no service is killed. Native ownership, actual device install results and real SMB/disconnect behavior remain unverified by fixture tests.

Implementation/validation: `Docs/Reports/sphaira-mtp-install-foundation-2026-10-25.md`. Native follow-up: `Docs/Reports/native-sphaira-mtp-2026-10-25.md`. Manual test instructions: `Docs/Guides/sphaira-mtp-install-test.md`. The specific package/device target is still for the user to confirm; the agent ran only fixtures, packaging and app launch, not a physical installation.

## Backend foundation wave — 2026-10-23

The user authorized supervised Orca agents to implement USB Backend software and hardware-free tests. `SwitchShelfBackend` owns transport-independent framing/session logic, allowlisted range reads, preparation checks and durable transfer state; `CDBIBackendUSB` owns the native USB adapter. The host protocol reference is pinned to rashevskyv/dbi `22090afc64cc7b5d645a99bf3d4d8625a67b766e` (`dbibackend`). No production UI or CLI may open a Backend transfer session in this wave. Native USB code is compiled and tested with fakes/argument checks only; actual installation requires a separately reviewed file/target test.

`BackendContracts.swift` is coordinator-owned for this wave. Protocol worker owns `SwitchShelfBackend/Protocol`; USB worker owns `CDBIBackendUSB` and `SwitchShelfBackend/USB`; UI/preflight worker owns `SwitchShelfApp` and `SwitchShelfBackend/Preflight`. A separate storage worker owns `SwitchShelfBackend/FileAccess`, `SwitchShelfBackend/Journal` and their tests. Coordinator owns the manifest, integration and final tests. Workers use separate child worktrees and must not launch further agents; the user's explicit delegation authorization applies to the coordinator.

Backend file exchange does not prove installation. Transfer outcomes are per file (`notRequested`, `partiallyTransferred`, `transferredAwaitingConfirmation`), and never promote a game to installed. SD/NAND selections remain local intent: the pinned host protocol does not encode a destination-setting command. Backend and MTP must not hold device sessions concurrently. No new source file reads, physical USB opens/writes, dependency installs or global settings changes are allowed in worker validation.

## Wireless FTP slice — 2026-10-26

`SwitchShelfDevice` owns a separate FTP client. It is not a USB transport and does not take `DeviceLease`. The pinned DBI README says Run FTP server accesses SD files on port 5000 and installs files on port 6000. `dbi.config` at that commit sets `[FTP] Port=5000` and `[HTTP] Port=1234`. This client opens only the file-access port, sends `USER anonymous`, `PASS anonymous`, `PWD`, `PASV` and `LIST`, then `QUIT` on disconnect. It never sends `STOR`, `RETR` or any other write. `LIST` text is not installed-game evidence and does not verify package identity. sphaira's network menu remains the documented way to enable MTP, not this Wi-Fi path. No physical Switch FTP session has been run.


The user requested pi as the preferred development agent due to quota on 2026-10-23. The three initial Codex dispatches were explicitly stopped with their worktrees preserved. pi structured-session creation was refused by the current Orca runtime; use the documented existing-terminal supervision route if required. Agent identity and underlying model/provider are separate; do not claim a different quota pool without evidence.
