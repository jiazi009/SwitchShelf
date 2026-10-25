# SwitchShelf coordinated development plan

## Current objective
Integrate the observed sphaira Games inventory into the existing native app, clarify connection/coverage status, preserve conservative local identity matching and deliver a tested local bundle. The coordinator owns this follow-up; existing Backend changes remain separate. Historical Orca waves below describe earlier work, not a newly dispatched run.

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
- Pin DBI Backend protocol reference, implement bounded file transfer and durable per-item state, validate with a specifically selected authorized package/target.
- Separate transfer completion and device confirmation, test disconnect/retry/cancellation semantics.
- Add lawful metadata/cover provider with source tracking/cache, correction layer, content-level install planning.
- P1 SD maintenance remains a separate workflow with preview, backup and recovery before writes.

## Real-device test instructions
Keep Switch connected by a data-capable USB cable. Enable MTP and Games in sphaira, or use DBI Run MTP responder with Installed games exposed. Keep that mode running. Tests enumerate storage descriptions and recognized game-content metadata only; do not copy files to installation storages. Quit OpenMTP and other MTP clients first. Record provider/version/environment only when independently known. Missing source, partial coverage and disconnected USB are different outcomes. Do not switch mode during a probe. Backend installation needs its separate reviewed file/target test.

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
