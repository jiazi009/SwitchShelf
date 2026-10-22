# Device service / read-only probe report

## Delivered

- `Sources/SwitchShelfDevice/DeviceService.swift`: public `DeviceService` actor with the agreed `init()`, `discover()` and `readInventory()` contract; IOKit discovery reads only vendor/product IDs and never declares a USB candidate ready.
- `NativePTPTransport.swift` / `PTPCodec.swift`: default macOS ImageCaptureCore broker transport, on MainActor, with one serialized metadata-only PTP session. This avoids competing with macOS `ptpcamerad` for the USB interface. Only GetStorageIDs (`1004`), GetStorageInfo (`1005`), GetObjectHandles (`1007`) and GetObjectInfo (`1008`) are allowed; no GetObject/file downloads or mutation commands.
- `NativeMTPSession.swift` / `Sources/CDBIBridge/**`: explicit stock-libmtp fallback via `dlopen`; no build-time libmtp/libusb headers or link dependency. Cached libusb descriptors are filtered to Nintendo `057e:201d` before opening one target, without libmtp's unrelated-device detection probes/log dumps. No bridge API supports transfer, deletion, installation, format, console reset or property writes.
- `InventoryReader.swift`: recursive Installed games metadata enumeration, including nested base/update/DLC objects, per-object metadata validation, duplicate/cycle detection, traversal limits, identity parsing and explicit partial coverage.
- `Sources/SwitchShelfProbe/main.swift`: discover/inventory JSON CLI, isolated child process with bounded deadline, owner-only temporary result file and suppressed native stdout/stderr.
- `Tests/SwitchShelfDeviceTests/DeviceTests.swift`: 35 hardware-free tests. Removed device/probe placeholders.

No Package.swift, shared domain, UI, library or scripts are part of this commit. For local builds I temporarily used the coordinator-approved root manifest's Swift tools 6.2 declaration, then restored this branch's original manifest; integration must use the coordinator's updated manifest.

## Commands (coordinator runs hardware reads only)

```sh
swift build --product switchshelf-probe
BIN="$(swift build --show-bin-path)"
"$BIN/switchshelf-probe" discover --timeout 10 --json
# Explicit opt-in; keep DBI in Run MTP responder, no other active device session:
"$BIN/switchshelf-probe" inventory --transport native --timeout 60 --json
# Only as a reviewed alternative, not simultaneously with the native session:
SWITCHSHELF_LIBMTP_PATH=/opt/homebrew/lib/libmtp.9.dylib \
  "$BIN/switchshelf-probe" inventory --transport libmtp --timeout 60 --json
```

With no arguments the CLI only discovers USB candidates. Exit codes: `0` successful observation, `2` incomplete inventory, `1` error, `64` invalid arguments, `124` deadline exceeded. JSON has `schemaVersion`, `mode`, `status`, and optional `transport`, `discovery`, `inventory`, `error`; dates are ISO-8601. A successful subprocess exit is not used as evidence of MTP readiness or a complete inventory.

The service defaults to the system broker; `SWITCHSHELF_MTP_TRANSPORT=libmtp` explicitly selects the fallback for service users. There is no automatic fallback/retry that could unexpectedly compete with the broker.

## Evidence and tests

Worker performed **no live USB discovery or MTP session**. Hardware facts below are coordinator observations delivered through orchestration, not independently reproduced worker results.

- `swift build --target SwitchShelfDevice`: passes, Swift 6 concurrency checking.
- `swift build --product switchshelf-probe`: passes.
- `swift test --filter 'DiscoveryTests|IdentityTests|InventoryTests|PTPTests'`: **35 tests pass**. Covers USB filtering/readiness, session-scoped identities, exact missing storage, genuine empty traversal, storage failure, nested content, duplicate projection identities, cycles/wrong parents, omitted metadata, parsing ambiguity/overflow, no parent identity inheritance, combined packages, excluded mods, folders with no attributable content, traversal budgets, PTP datasets/responses/opcode allowlist and missing runtime.
- Missing-runtime test uses a guaranteed nonexistent explicit path, failing before any libusb enumeration; repeated attempts verify gate release.
- CLI `--help` works; invalid timeout returns JSON usage/64; missing runtime fallback returns actionable `runtimeMissing`/1 without USB access.
- Hardware-free CLI deadline test: launched the real parent with argv[0] pointing to a replacement worker script containing `exec /bin/sleep 10`; `--timeout 1` returned JSON timeout/124 in **1.011 seconds**. No device code executed.
- Both header-free and official-header validation compile cleanly:

```sh
clang -std=c11 -ISources/CDBIBridge/include -Wall -Wextra -Werror \
  -fsyntax-only Sources/CDBIBridge/bridge.c
clang -std=c11 -DSS_VERIFY_LIBMTP_ABI \
  -I/opt/homebrew/include -I/opt/homebrew/include/libusb-1.0 \
  -ISources/CDBIBridge/include -Wall -Wextra -Werror \
  -fsyntax-only Sources/CDBIBridge/bridge.c
```

`libmtp_abi.h` includes optional compile-time size/offset/constant assertions against official **libmtp 1.1.23 (ABI 9)** and **libusb 1.0.30** headers. Function signatures were checked against the installed headers; these private declarations expose only the required layouts/functions, not upstream implementation code. `otool -L` confirms the probe has only system framework/Swift dependencies, including IOKit/ImageCaptureCore, and **no hard Homebrew dylib dependency**.

### Coordinator hardware evidence

- IOKit recognized Nintendo `057e:201d`.
- Stock `mtp-detect` exited 0 despite `libusb_claim_interface() = -3` / inability to initialize the device. IOKit showed `ptpcamerad` owning its interface. We therefore never equate utility exit status or VID alone with readiness, and fallback open failure is honestly classified `accessDeniedOrBusy` because libmtp returns NULL without a discriminating libusb error.
- Coordinator's native broker prototype successfully opened a session, got nine storage IDs and storage metadata, and closed the session. Broker responses reassign transaction IDs, so codec validates response length, container type and success code but deliberately does not require the caller's transaction ID to be echoed; one request is in flight.
- Coordinator ran this worker's compiled probe with `inventory --transport native --timeout 30`: **exit 2, partial, `isComplete=false`, no Installed games storage, correct actionable issue**. Native communication and session close worked.
- User reports DBI **647-zhcn** and firmware display **19.0.1e**. Coordinator's separate read-only small-config inspection found `[MTP Storages] 4: Installed games=false`; custom SD storage is exposed as `1: SD内存卡`. This worker never read/downloaded that config and the service does not contain a config-download opcode.
- Enabling Installed games is a **user/coordinator decision**, not an application mutation. Full installed-content traversal, exact DBI filename conventions and sysMMC/emuMMC identity remain **unverified** until the user exposes that storage and coordinator repeats the read. Firmware text is not used to invent a runtime environment identity.

## Truthfulness and boundaries

- Discovery permits only `057e:201d` (Switch MTP candidate) and `057e:3000` (documented DBI Backend candidate); controllers, `057e:2000`, other vendors and unknown Nintendo PIDs are not treated as DBI. Even the MTP pair remains `waitingForMTP`, never `ready` from descriptors.
- New random device IDs are generated for each USB observation and each opened inventory session. Environment stays `nil`/unknown; no serial, USB address or location is used as a stable identity. Serial properties are never queried or emitted.
- Storage must be exactly `Installed games` or `4: Installed games` (case/outer whitespace insensitive), not any name containing those words. Missing/hidden storage is partial with guidance, never an empty complete inventory. Storage-query failure throws; directory/metadata/parse failures preserve any partial records and make coverage incomplete.
- Only explicit delimited filename tokens are parsed: `[01xxxxxxxxxxxxxx]` or `[titleid=...]`, `[v<unsigned decimal>]` / `[version=<unsigned decimal or 0xhex>]`, and explicit `[BASE|Application]`, `[UPD|Update|Patch]`, `[DLC|AddOnContent]`. Missing/conflicting/overflowing identity fields remain unknown and prevent completeness. No display-title matching, display-version conversion, TitleID arithmetic, or parent identity inheritance. This grammar is fixture-tested, **not a claim that target DBI 647 emits all these tokens**.
- DBI documents root virtual packages as combined projections. They are omitted from per-content records to avoid double-counting nested contents, with an incomplete-coverage issue until aggregate coverage can be verified. Nested records are deduplicated only for identical unambiguous `(TitleID, kind, rawVersion)` tuples; nothing is inferred from names alone.
- The documented `Mods & Cheats` redirect is not traversed. Other unrecognized files or a game folder without attributable content make coverage incomplete rather than hiding possible content.
- Defaults: 100,000 objects, depth 64, monotonic 45-second traversal budget. Diagnostics are bounded; handles/errors are numeric or safe fixed messages, not arbitrary native exception text. Native PTP codec bounds counts/dataset lengths, checks UTF-16 terminators, fixed field offsets, parent/storage consistency and response success. Unsupported extensions/quirks fail closed rather than reporting complete.
- One process-wide coordinator gate remains held across awaits; a C atomic gate also excludes multiple fallback sessions. Handles, child arrays, file metadata, storage strings and normal sessions are released on every success/error path. Normal broker close failure downgrades inventory completeness. No manual reset, device eject, daemon kill, global setting change, storage/object write, save access, installation or full game-file download occurs.
- **Timeout limitation:** the CLI supervisor stops its worker with SIGTERM then SIGKILL if needed, so OS process teardown releases USB resources; graceful protocol CloseSession cannot be guaranteed after a hard deadline. Within the app, native callback/libmtp calls cannot be forcibly cancelled safely: traversal cancellation/budget is checked between metadata calls, not a guaranteed hard bound on an OS/native call. No concurrent retry is started.

## Runtime paths / distribution

Default native transport uses the system ImageCaptureCore framework and requires no developer package install. Swift imports auto-link the required system frameworks; no manifest framework edit was needed here. App privacy/sandbox requirements and signed-bundle validation remain coordinator packaging responsibilities.

For the optional fallback, initial load searches:

1. `SWITCHSHELF_LIBMTP_PATH` if nonempty (explicit initial override; no fallback on failure).
2. `Bundle.main.privateFrameworksURL/libmtp.dylib`, then `libmtp.9.dylib` if present.
3. Executable-relative `../Frameworks/libmtp.dylib`, then `libmtp.9.dylib`.
4. `/opt/homebrew/lib/libmtp.9.dylib`, `/usr/local/lib/libmtp.9.dylib` (development only).

Loaded runtime code stays resident for process lifetime because libmtp has a process-global USB context without a public shutdown API; actual device sessions always close. Restart after changing the runtime selection. A distributable bundle must include the matching libmtp/libusb dylibs, fix dependent install names/rpaths, sign nested code, and validate on a machine without Homebrew. Do not require end users to install development tooling.

**Library behavior reviewed with coordinator:** stock libmtp may internally call `libusb_reset_device` after a failed OpenSession, and for flagged devices on release. The coordinator explicitly clarified this reversible USB transport recovery is allowed; console reboot/factory reset, formatting, object mutation, and manual USB-reset commands remain forbidden. The bridge adds no manual reset/retry loop. Switch's official table entry has flags NONE.

### Primary sources and license checks

- DBI fixed reference: [README, Run MTP responder](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/README.md#run-mtp-responder), including Installed games, combined root NSPs and Mods & Cheats behavior. No DBI implementation/script code copied.
- libmtp [1.1.23 public header/source](https://github.com/libmtp/libmtp/tree/v1.1.23/src), especially `libmtp.h`, `music-players.h` (`057e:201d`, NONE), `libmtp.c`, `libusb1-glue.c` (session/release/recovery), `ptp-pack.c` (StorageInfo offset 26; ObjectInfo filename offset 52, parent offset 38). Installed header: `/opt/homebrew/opt/libmtp/include/libmtp.h`.
- Apple SDK `ImageCaptureCore.framework/Headers/ICDevice.h`, `ICCameraDevice.h`, `ICDeviceBrowser.h`: asynchronous session and PTP command APIs, capability requirement and callback threading. Browser/camera access stays MainActor.
- Installed libmtp header states **LGPL-2.0-or-later**; distributed `/opt/homebrew/Cellar/libmtp/1.1.23/COPYING` is **LGPL 2.1** and was read. Section 5 addresses numeric constants/data layouts; this bridge contains only minimal ABI declarations, not linked/copied implementation. Installed libusb header states **LGPL-2.1-or-later**.
- Bundling these libraries still requires copyright/license notices, the license text, corresponding-source/replacement/relinking compliance as applicable, and compatible signing/distribution arrangements. Dynamic loading alone is **not** an exemption. Coordinator must include third-party notices/licenses and review final distribution compliance.

## Remaining acceptance

Coordinator integration/cherry-pick and signed bundle validation; user-controlled Installed games visibility; one exclusive coordinator live traversal with real object-name/identity evidence; future support for verified DBI naming variants/aggregate coverage if needed. No installation execution capability is provided or implied by this delivery.
