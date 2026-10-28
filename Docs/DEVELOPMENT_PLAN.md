# SwitchShelf coordinated development plan

## Installation-first staging UI — 2026-10-28

Implemented the confirmed interaction: multiple card clicks accumulate the persistent plan in a fixed 320-point right sidebar, artwork animates into it, and a bottom start button remains visible. Card info controls open a separate closable detail popover without staging or install controls. Base/all DLC/uniquely newest same-identity update are defaults; ambiguous updates require a choice or explicit current-session omission. Start automatically preflights then presents the existing file/device/target confirmation in the library; the reviewed serial transfer engine is unchanged. Existing plans and source data are preserved.

Validation: 285 offline tests, 51 cover checks, light/dark native WindowGroup regressions (including real in-process mouse events for grid/list info/body/close and the start button), staging/default/ambiguity/locking/target/persistence checks, and 24 layouts in both motion modes pass. The native tests assert sidebar/button positions and animation endpoints, not just window survival. Release packaging/signing passes. Actual App visibility is confirmed by the system window list; external AX/screenshot reads are currently blocked despite reported permission grants, so this limitation is not represented as a successful screenshot acceptance. No physical installation or device write occurred. Details: `Docs/Reports/install-staging-redesign-2026-10-28.md`.

## Native UI layout and inspector optimization — 2026-10-27

Follow-up caught a display regression that process/window-size checks had missed: the native split pane retained a 1059-point ideal height and clipped its header in smaller windows. Library/sidebar panes now explicitly allow vertical compression. Real-window tests assert header/brand positions inside four viewport sizes, not just process survival. Selection no longer repeats whole-library sorting for plain clicks; inspector rows are lazy, and bounded artwork decoding/palette sampling runs off MainActor with validated decoded-image reuse. Native inspector behavior remains, with Reduce Motion respected. The 285-test offline suite, 51 cover checks, native selection/modifier/reopen regressions, 24 layouts and release signing pass. Reopened the actual 16-game window and verified card selection/detail display without queue writes. Synthetic CPU measurements are not animation FPS; full frame-time acceptance remains separate. Details: `Docs/Reports/ui-layout-and-inspector-performance-2026-10-27.md`.

## Empty-library startup crash fix — 2026-10-27

Removing the last source exposed an AppKit/SwiftUI constraint-update loop, reproduced in an isolated real production WindowGroup. Empty libraries now omit the native inspector entirely (hiding it alone was insufficient); minimum dimensions are declared by the SwiftUI root instead of being written during NSView attachment. Empty startup, resize, populated-to-empty source removal and device-page round trips pass in light/dark native-window regressions. The full 285-test offline suite, release packaging and signing pass. The actual test app now opens the user's unchanged zero-source library without a new crash. Automatic device inventory still reports a separate read failure; no installation was attempted. See `Docs/Reports/empty-library-startup-crash-2026-10-27.md`.

## libusb inventory comparison follow-up — 2026-10-27

The user narrowed the independent connection experiment to libusb versus the existing ImageCaptureCore route, using OpenMTP as a reference; libmtp comparison is excluded. Branch `codex/mtp-transport-comparison` provides a metadata-only libusb transport, explicit probe selection and a session-only device-page selector. Installation, default startup route and source-game files are unchanged. Previously captured physical read-only probes on both routes agree on 9 storages, 8 Games directories and 22 records; the continuation verified those saved results rather than repeating hardware access. Remaining acceptance: GUI first-use authorization behavior and repeated physical reconnects, not installation tests. Independent app and manual instructions: `Docs/Reports/libusb-inventory-comparison-2026-10-27.md`. No merge into main is part of this work.

## Installation UI update — 2026-10-27

The user reports that installation testing has passed and requested production-facing queue wording. The app no longer labels the queue as awaiting hardware acceptance or calls installation a test. The specific test files, device configuration and outcomes were not supplied, so this report does not establish broader hardware coverage. Transfer completion remains distinct from device-confirmed installation.

## Integration checkpoint — 2026-10-27

The local main branch combines automatic USB discovery and cached historical inventory, the device session overview, the separate DBI FTP page, and the reviewed serial installation queue. FTP connection blocks USB discovery and installation; cached inventory remains historical until a current-session read. The queue uses the existing isolated single-file helper for each item, stops on uncertain results, and never treats transfer as proof of installation. At this checkpoint the integration had not been validated by a physical installation or a real FTP session; the historical single-file checkpoints below describe the earlier implementation.

## Current objective
Continue the user-selected **sphaira MTP inventory + installation** route. Preserve the accepted Games inventory and conservative identity matching; implement installation in gated stages. Backend is deferred and its existing uncommitted changes remain separate. Historical Orca waves below describe earlier work, not a newly dispatched run.

## Separate Wi-Fi slice — 2026-10-26

This branch adds a DBI FTP page beside the existing USB MTP path. It does not replace sphaira/DBI inventory or the single-file install test. The pinned README (`22090af`) describes Run FTP server as SD file access on port 5000 and installation on port 6000; the client uses 5000 only. HTTP metadata for build 647 stays unverified. The first host that reaches the connected phase is kept in UserDefaults and is not replaced by later results. No Switch address is stored until that happens. Tests are fixtures and a loopback server, not a session to a Switch. Details: `Docs/Reports/wifi-ftp-connection-2026-10-26.md`.

## Native sphaira MTP test package — 2026-10-25

- User requested native MTP integration, repackaging and an app run for their manual test. Added a real bounded libusb transport with same-session PTP inspection, packet-aligned stream/final ZLP handling and no driver detach/reset. Inventory remains ImageCaptureCore.
- Wired a single direct child helper with pre-open DeviceLease, immutable source-review fingerprint, durable conservative records, progress, cancellation, USB/stall/total deadlines, verified process exit, unknown-state reporting and no automatic retry/resume. UI requires one selected file, passing current preflight and explicit per-file/device confirmations. This is an experimental manual-test flow, not completed hardware acceptance.
- Validation: 200 tests passed (189 Swift Testing plus 11 XCTest); 17 new tests include fake USB packet boundaries and real local child-process stop/exit checks. Strict C/libusb ABI checks, release packaging, bundled-library load without USB initialization and signature verification pass. App 0.3.0 started; live AX/screenshot shows the single-file test page. No game was sent and no physical installation session opened by agent validation.
- The existing user queue has one plan with two included files; it was preserved. The user must choose one file and confirm their actual device settings. Native exclusive interface access, device result and real SMB behavior still require that manual test. Details: `Docs/Reports/native-sphaira-mtp-2026-10-25.md`; steps: `Docs/Guides/sphaira-mtp-install-test.md`. Backend, manifest, domain and icon work remain untouched.

## sphaira installation software checkpoint — 2026-10-25 (historical foundation)

- Completed: pinned upstream source review; sphaira-specific metadata-only plan checks in the app; separate upload wire codec; single-file bounded streaming state machine; read-only descriptor-pinned source access; 32 new fixture/local-temporary-file tests. No manifest or shared domain changes. App guidance now explains MTP Install mode and device-side destination selection, not Backend.
- Validation: `swift test --skip RealNASScanTests` passed (172 Swift Testing tests plus 11 XCTest tests), release app/probe packaging and strict signature verification passed. No source-game bytes or physical USB installation access occurred. See `Docs/Reports/sphaira-mtp-install-foundation-2026-10-25.md`.
- Next software gates: implement/verify a bounded native upload adapter and same-session capability inspection; integrate machine-wide lease and process-isolated deadlines with positive exit verification; add durable conservative transfer state and explicit file/target confirmation. Do not materialize large packages into ImageCaptureCore outData, infer device build from upstream, or automatically retry a failed installation stream.
- Next hardware gate: review `Docs/Tasks/sphaira-mtp-install-field-test.md`, explicitly select one authorized test package and confirm destination/settings on sphaira. Only after that review may an installation test be scheduled. Upload logic is still internal/unwired; the app's Start button remains disabled. A host OK response must not promote installed state.

## Current connection baseline — 2026-10-25

- DBI 647-zhcn / FW 19.0.1E was verified in the user's screenshots. Both the current device config and DBI's own UI enable Installed games, yet two host clients report nine storages without that entry. DBI build/config behavior remains unresolved; this no longer blocks another MTP provider.
- After the user opened sphaira, OpenMTP displayed Games with ten game directories and explicit nested BASE/UPD/DLC filenames. All enabled MTP entries were DevNull, Mounts, Install, Games, three Contents entries, Album (Image SD), and microSD card. These are actual observations; coverage must also be validated with the project's own bounded reader.
- Integrate Games, show bounded source/storage evidence, preserve old helper JSON compatibility and test actual observed names plus failure/coverage boundaries. The exclusive read-only native probe and app path were exercised after quitting OpenMTP; a live virtual-handle mismatch required a narrowly scoped correction and follow-up probes. No package transfer or device write was part of this acceptance.
- Keep local filename identities as candidates. A complete device catalog alone cannot verify NAS packages. Generate app-icon concepts for user selection and add ICNS packaging; do not choose a final icon on the user's behalf.

Outcomes and remaining limits: `Docs/Reports/sphaira-inventory-acceptance-2026-10-25.md`. Final native read and app retry both reported Games, ten directories and 29 BASE/UPD/DLC records, complete with no issues. The first app read failed transiently; investigate reliability rather than assuming a guaranteed first-try connection. Cached local package identities still display 待确认. The selected icon direction 05 has a simpler 07 review candidate, not a confirmed bundle icon.

## Wave 1 — parallel foundations
1. opencode / UI: native three-column library, search/list/filter/multi-select, inspector, device/connect instructions, persistent install plan with honest disabled execution until transport exists.
2. agy / library: SMB-safe read-only scanner, candidate identities/content grouping, SQLite cache/bookmarks, offline preservation, tests using temporary fixtures; exercise the real NAS tree read-only with bounded I/O.
3. pi / device: USB enumeration, DBI mode guidance, dynamic libmtp read-only inventory, CLI probe with JSON and timeout/error handling; document version/field evidence.
4. Coordinator: domain contracts, real-data composition, installed-state matching, packaging and acceptance.

## Wave 2 — integrate and validate
- Review and cherry-pick isolated worker commits; build and run tests.
- Run real NAS scan, compare counts and inspect grouping; no filename-only claim of verification.
- User enters DBI Run MTP responder; coordinator runs a single read-only client and records version, storage coverage and reliable identities.
- Exercise light/dark/narrow layout, library navigation/search, offline cache, queue editing and inventory badge truthfulness.
- Package a local .app, include run instructions and summarize remaining capability gates.

## Wave 3 — installation and metadata
- Primary route is now sphaira MTP: implement bounded native package streaming and durable per-item state, then validate with a specifically selected authorized package/target. Preserve the existing pinned DBI Backend work as a deferred alternative; do not develop two production installation paths in parallel.
- Separate transfer completion and device confirmation, test disconnect/retry/cancellation semantics.
- Add lawful metadata/cover provider with source tracking/cache, correction layer, content-level install planning.
- P1 SD maintenance remains a separate workflow with preview, backup and recovery before writes.

## Real-device test instructions
Keep Switch connected by a data-capable USB cable. Enable MTP and Games in sphaira, or use DBI Run MTP responder with Installed games exposed. Keep that mode running. Tests enumerate storage descriptions and recognized game-content metadata only; do not copy files to installation storages. Quit OpenMTP and other MTP clients first. Record provider/version/environment only when independently known. Missing source, partial coverage and disconnected USB are different outcomes. Do not switch mode during a probe. The native sphaira single-file installation test is separate from these read-only probes: follow `Docs/Guides/sphaira-mtp-install-test.md` and require the user's concrete file/target confirmation before sending. Backend remains deferred.

## Completion criteria and tracking
Every task records implementation paths, tests, commit, hardware evidence and limitations. Place persistent reports in Docs/Reports. Completed UI does not prove device capability; passing fixture tests does not prove SMB disconnect or Switch protocol behavior. Update this plan with actual outcomes as development proceeds.

## Acceptance follow-up — 2026-10-23

- `codex/source-access-recovery` / `0b154a5`: existing source selection now refreshes its access bookmark; background bookmark resolution does not show UI.
- 84 tests, debug build, local app packaging and ad-hoc signature verification pass. A fresh actual app launch persisted 16 games / 48 packages / 0 scan issues to its own cache; the previous app scan stall did not recur and its cause remains unknown.
- Orca CLI window observation still fails with `permission_denied` despite granted permission status. After the user's permission screenshots, the available `cua_repl` native control channel verified the real 16-game window, search (one Zelda result), grid/list switching and selection. Inspector AX remains conservatively unknown for installation; its screenshot area needs further visual verification.
- Queue editing/persistence, offline scenarios, dark and 960×640 layouts remain pending. No real device probe was performed without the user's DBI readiness confirmation. Next: remaining live UI checks and one confirmed exclusive read-only DBI inventory. Details: `Docs/Reports/source-access-followup.md` and the updated `project-handoff.md`.

## DBI storage diagnosis — 2026-10-23

- After the user's configuration/restart confirmation, one bounded inventory attempt returned partial. A new storage-only diagnostic (`c9fe0c4`) then observed nine storage descriptions before and after a user-performed USB reconnect; Installed games was absent both times. All processes exited normally; no content objects, transfers, installs or device writes were requested by the diagnostic mode.
- The user confirms DBI itself displays a normal installed-game list. Active configuration loading and this build's MTP behavior remain unresolved; keep app installation states unknown rather than interpreting zero parsed records as an empty device.
- 86 tests pass (30 library, 8 domain, 48 device), including storage diagnostics that remain incomplete and never traverse content even when a recognized target exists. Debug build, app packaging and ad-hoc signature verification pass.
- User asked about alternatives: recommend USB Backend for future installation while inventory remains a separate capability; FTP/HTTP are network options with unverified 647 inventory semantics. No installation or network-service activation is authorized by this discussion. Latest evidence, sources and next checks: `Docs/Reports/mtp-storage-diagnosis.md`.


## Backend software foundation acceptance — 2026-10-23

- Per user quota preference, stopped the three initial Codex workers and completed the wave through three pi terminals. Run `run_b35d87130bcd` has nine completed tasks and no reclaimable terminals; all accepted worker commits are reviewed/cherry-picked onto `codex/source-access-recovery`. pi currently defaults to `openai-codex/gpt-6-sol`; no different quota pool is asserted and no global setting was changed.
- Implemented the pinned DBI host session, native explicit-open USB adapter, allowlisted bounded range reader, durable conservative journal, metadata-only preflight and queue guidance. Production native open/transfer remains unwired; no physical Backend session or installation occurred.
- Root validation: 127 tests with `swift test --skip RealNASScanTests`, then 2 new integration tests; 129 total passed. Native strict C checks, release packaging and ad-hoc signature verification pass. Backend contributes 44 new fixture/fake tests.
- Actual app shows 16 cached games and a normal selected inspector; local queue preflight passed for 2 files, became stale after changing inclusion, then passed for 1 file. Start stayed disabled. Temporary plan removed; persisted queue is empty. Orca CLI observation is working after app/window startup; do not repeat permission toggles without new evidence.
- Next software gates: one concrete cross-process MTP/Backend lease, independent helper/process exit verification for native/SMB hard deadlines, then a reviewed authorized small-package/target/device-result test. Current inventory remains unknown; no repeated MTP probe under unchanged conditions. Dark/narrow/real-offline GUI acceptance is still pending. Full evidence: `Docs/Reports/backend-foundation-acceptance.md`.
