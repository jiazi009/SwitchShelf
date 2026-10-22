# SwitchShelf acceptance checkpoint — 2026-10-23

This is a **partial acceptance**, not a claim that the device inventory or live UI has passed. Coordinator for Orca Run `run_6bf908529b8b`, generation 2. The preexisting opencode UI, agy library, and pi device workers all returned `worker_done` with reports and commits; no replacement workers were spawned or other worktrees overwritten. The UI worker's unrelated, uncommitted `Package.swift` change was not integrated. Detailed evidence: `Docs/Reports/coordinator-integration.md`, `ui-opencode.md`, `device-647-compatibility.md`, `hardware-connection-647.md`.

| Requirement | Evidence / status |
|---|---|
| Native macOS 26+/Swift 6 UI in selected liquid-glass direction | `Sources/SwitchShelfApp/**` integrated from `dd94bb8`, local `.app` built and ad-hoc signed. Offscreen UI snapshots were checked by the UI worker. Live glass rendering and interaction **not yet verified** because Orca Computer Use returned `permission_denied` in the locked graphical session. |
| Real read-only SMB library | `swift test` read `/Volumes/switch 游戏包` metadata: **16 grouped games / 48 packages / 0 scan issues**; 92,313,880,284 bytes are reported metadata totals, not hashes or copies. All filename identities remain candidates. A launched app process/window existed, but its own NAS enumeration stalled in `NSURLDirectoryEnumerator`/`open`; therefore **presentation of the real 16 games inside the live UI is unverified**. App cache currently contains zero games; no fabricated UI result is claimed. |
| Cache and plan | SQLite repository, partial-scan preservation, multi-source merge, and cache migration tests pass. A 215-byte prototype JSON cache was preserved under `library.sqlite.legacy-json-…` and imported to SQLite on the local launch. Unknown/corrupt cache files are not overwritten. The queue is an editable local plan; install execution is visibly disabled. |
| USB/DBI 647 | Read-only USB discovery saw one `057e:201d` MTP **candidate**, not an authenticated inventory. The tested DBI storage exposure before a confirmed restart did not show `4: Installed games`; post-restart object names, completeness and installed records are **unknown**. The app bundles a bounded, serialized, read-only `switchshelf-probe`; mock-process tests pass. No real post-restart inventory probe was made. |
| Automated checks | Integrated `swift test`: **84 pass** (library 30, domain 8, device 46); `swift build`, `python3 scripts/build-app.py` and `codesign --verify --deep --strict build/SwitchShelf.app` pass. This is local ad-hoc signing, not notarization or distribution approval. |

## Follow-up required from user

1. Unlock the Mac desktop and confirm the SwitchShelf window can be shown. If macOS requests access to the NAS or Orca Computer Use accessibility/screen capture, review/approve it in the local GUI. The CLI reported Accessibility and Screenshots granted, while actual window observation still returned `permission_denied`; cause is unproven. Then repeat live UI/content/interaction acceptance.
2. On the Switch, fully exit and reopen DBI after enabling `4: Installed games=true`, enter **「运行 MTP 传输程序」**, leave it there and confirm this is done. Close any other MTP/USB clients first. Only then the coordinator can use one exclusive bounded, read-only inventory probe. Do not change settings, install or delete device content as part of that probe.
3. If the post-restart inventory omits Installed games or is partial, record observed storage names/object metadata verbatim and leave identities/coverage unknown. No inferred installed badges or compatibility rule without real evidence.

## Files / commits

- Integrated UI: `dd94bb8`, report `833a197` (`Sources/SwitchShelfApp/**`, `Docs/Reports/ui-opencode.md`).
- Integration safety: `3dc5044` (`AppModel.swift`, `LibraryCacheMigration.swift`, migration tests); prior bounded probe `1347e72`. This acceptance report and integration chronology are in `Docs/Reports/`.
- The deliverable is `build/SwitchShelf.app` locally; installation/transfer/deletion and device writes are not implemented or authorized. Source game packages were never moved, modified, uploaded or fully hashed.
