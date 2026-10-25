# sphaira Games — read-only integration acceptance (2026-10-25)

## Scope and observed evidence

OpenMTP was exited before the project probes. IOKit discovery saw one Nintendo Switch USB candidate (`057e:201d`); this alone did not prove an MTP session. The Switch was left in sphaira MTP mode. Tests used only PTP `GetStorageIDs`, `GetStorageInfo`, `GetObjectHandles` and `GetObjectInfo`; no object bytes, source game bytes or device writes were requested. The native ImageCaptureCore broker was not disabled.

The first project probe connected and found nine storage descriptions, including `Games`, but returned **incomplete, zero records**: all ten top-level objects failed its strict location check. An additional metadata-only diagnostic exposed sphaira's virtual handle convention: in that session the Games storage was `0xFFFFFFF9`, while the object info advertised `0xFFFFFFFE` for its storage and `0xFFFFFFF9` for its top-level parent. These are session-scoped handles, not device identities. The reader now permits this exact virtual-storage alias and storage-root parent only for a storage whose description is `Games`; DBI `Installed games` and ordinary SD storage retain strict location checks. A wrong Games parent is still rejected. Error diagnostics contain only numeric transient handles, not filenames.

A rebuilt, isolated native `switchshelf-probe inventory --timeout 90 --json` exited **0**, reporting `isComplete=true`, no issues, `Games` as the sole traversed storage, **10 game directories, 39 metadata objects and 29 per-content records**: 10 BASE, 9 UPD, 10 DLC. All 29 had explicit filename Title ID, raw version and content-kind tokens. The remaining eight storages were catalogued by description only. A probe from the signed app bundle independently returned the same complete counts.

The rebuilt `build/SwitchShelf.app` kept the previously cached 16 local games. The first app-button read returned a generic MTP read failure with unknown coverage; no installed result was shown. With the device still in the same mode, a later app-button retry returned **“MTP 已连接 · Games · 已读取完整内容清单”**, 29 records and the 10/9/10 kind counts. Selecting the cached local `1-2-Switch` showed **“已匹配 · 待确认”** and explicitly said that the local package's Title ID is only a filename candidate. The first transient app-read failure remains unexplained; do not turn one successful retry into a reliability claim.

## Validation and boundaries

- `swift test --skip RealNASScanTests` passed (Swift Testing suites: 29 + 8 + 63 + 34 + 6 tests; XCTest suites also passed). The new sphaira tests cover the live virtual-handle convention, DBI rejection, and wrong-parent rejection.
- `python3 scripts/build-app.py` passed; `codesign --verify --deep --strict build/SwitchShelf.app` passed. No unselected icon was installed as the bundle icon.
- Full live content identity is **projection metadata**, not decrypted package verification, a stable console identity, a proven OS/environment version, or an installation transaction. Local NAS filenames remain candidates. Incomplete/failed reads remain unknown; a complete Games projection must not be extended to other MTP providers.
- No installation, package transfer, deletion, save modification, formatting, full SMB hash, or automatic device retry was performed. DBI's absent `Installed games` storage remains a separate unresolved provider-specific issue.

## Icon iteration

The user's selected direction is concept `05-switch-sync.png`. `Assets/AppIconConcepts/07-switch-sync-simplified.svg` and its 1024px PNG are a **review candidate** based on it: one thumbstick per side, a single thin screen/tile rim, a simple folder and two flat arrows without bloom. It is not yet the selected bundle icon; obtain user confirmation before shipping it as the default.
