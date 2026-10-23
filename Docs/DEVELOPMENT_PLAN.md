# SwitchShelf coordinated development plan

## Current objective
Use the selected liquid-glass design to develop the native app under Orca supervision with opencode, agy and pi. The coordinator owns architecture, integration and acceptance. Deliver working code and evidence; keep real hardware dependencies visible.

## Wave 1 — parallel foundations
1. opencode / UI: native three-column library, search/list/filter/multi-select, inspector, device/connect instructions, persistent install plan with honest disabled execution until transport exists.
2. agy / library: SMB-safe read-only scanner, candidate identities/content grouping, SQLite cache/bookmarks, offline preservation, tests using temporary fixtures; exercise the real NAS tree read-only with bounded I/O.
3. pi / device: USB enumeration, DBI mode guidance, dynamic libmtp read-only inventory, CLI probe with JSON and timeout/error handling; document version/field evidence.
4. Coordinator: domain contracts, real-data composition, installed-state matching, packaging and acceptance.

## Wave 2 — integrate and validate
- Merge isolated worker commits after review; build and run tests.
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
Keep Switch connected by a data-capable USB cable; open DBI and choose Run MTP responder (X is a shortcut on versions documenting it). Stay on that screen. First test only enumerates storage and installed content; do not copy files to SD install/NAND install. Quit other MTP clients before the probe. For missing storage, inspect Installed games visibility in DBI settings; no config changes without explanation. Record DBI version and active sysMMC/emuMMC if known. Do not switch mode during a probe. The coordinator will request a switch to Backend only for a later installation test.

## Completion criteria and tracking
Every task records implementation paths, tests, commit, hardware evidence and limitations. Place persistent reports in Docs/Reports. Completed UI does not prove device capability; passing fixture tests does not prove SMB disconnect or Switch protocol behavior. Update this plan with actual outcomes as development proceeds.

## Acceptance follow-up — 2026-10-23

- `codex/source-access-recovery` / `0b154a5`: existing source selection now refreshes its access bookmark; background bookmark resolution does not show UI.
- 84 tests, debug build, local app packaging and ad-hoc signature verification pass. A fresh actual app launch persisted 16 games / 48 packages / 0 scan issues to its own cache; the previous app scan stall did not recur and its cause remains unknown.
- Live UI observation still fails with `permission_denied` despite granted permission status. Search/list/queue/layout acceptance remains pending. No real device probe was performed without the user's DBI readiness confirmation.
- Next: user unlock/permission review, then live UI checks and one confirmed exclusive read-only DBI inventory. Details: `Docs/Reports/source-access-followup.md` and the updated `project-handoff.md`.

