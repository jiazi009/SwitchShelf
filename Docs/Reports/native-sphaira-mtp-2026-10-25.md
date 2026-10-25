# Native sphaira MTP single-file test integration — 2026-10-25

## Delivered scope

User requested actual native MTP integration, repackaging, and running the app for their manual installation test. Implemented an **experimental, explicitly confirmed single-file flow**, not a claim of hardware acceptance or a production batch installer. Backend, Package.swift, shared domain, README and icon-source changes already in the workspace were not edited/included in this change.

No physical installation session was opened by agent validation. No source-game contents were read, copied, hashed, sent or modified by the agent. No device objects/saves/storage were deleted, altered or formatted. The source bytes used by tests were local temporary fixtures only. The user must select their actual file and confirm their device settings.

## Native transport

- `Sources/CDBIBridge/sphaira_usb.c`, `include/SphairaUSB.h` and the umbrella header: explicit-open, dynamically loaded libusb 1.0 ABI. Select exactly one `057e:201d` candidate and one active-alt-0 PTP interface (`06/01/01`) with bounded bulk endpoints. No driver detach/capture, reset, configuration change, shell tool or silent destination fallback.
- `Sources/SwitchShelfDevice/NativeSphairaMTP.swift`: Swift actor around the native USB handle and independently testable raw-link framing. GetDeviceInfo, OpenSession, GetStorageIDs/GetStorageInfo happen in the same physical session. Provider description, operation support, unique Games/Install storage and transient transaction IDs are checked before package reads/creation. Metadata is bounded; serial strings are parsed for dataset integrity but never retained/logged.
- Upload uses the existing separate `0x9808` + `0x100d` codec/engine. Header and payload are coalesced into bounded packet-aligned native writes; an isolated 12-byte header cannot terminate the phase prematurely. Final short packet or ZLP ends the data phase. Full/high/super-speed packet sizes 64/512/1024 are covered by scripted tests. No whole-file Data or partial-object seek/edit operation is used. Source chunks default to 1 MiB; each native write is at most 1 MiB; no packet-sized syscall for each tiny source fragment.
- Native USB calls have 20-second timeouts. Interrupted/uncertain phases close the raw interface rather than injecting a CloseSession command into data bytes. A failed release is separately recorded; positive helper exit is still required. Device-side rollback/completion is not inferred from host close.
- Inventory still uses the existing ImageCaptureCore broker and metadata-only allowlist. The installation bridge is separate; there is no Backend or libmtp upload fallback.

## Confirmation, files, isolation and state

- `SphairaInstallRequest.swift`: immutable per-file metadata review captures path, size, inode/device/mtime/ctime fingerprint and local intended target. Confirmation is initially false. The worker revalidates the exact review before opening the source. No package identity/compatibility is inferred from filename or fingerprint.
- `SphairaPackageSource.swift`: continues read-only component-by-component no-symlink open and bounded pread, now additionally checked against the reviewed fingerprint.
- `SphairaInstallWorker.swift`: validates confirmation/source, saves a durable opening record, acquires machine-wide DeviceLease, then creates the native transport. Saves side-effect intent before the first create command and bounded/throttled progress. Same attempt replay is refused without overwriting previous evidence.
- `SphairaInstaller.swift`: private 0700 attempt directory created with exclusive POSIX mkdir, owner-only bounded atomic/fsync JSON files; one direct child, not an orphanable child-of-supervisor chain. No duplicate attempt directory can overwrite an earlier request. Parent verifies actual process termination after cancellation/SIGTERM/SIGKILL escalation. Default inactivity deadline 120 seconds; total deadline two hours. Unverified exit fences later requests. A bounded callback relay cannot suspend deadlines even if a UI callback blocks.
- `Sources/SwitchShelfProbe/main.swift`: separate internal token + parent-PID-gated install entry point; ordinary discover/inventory/storages remain read-only. Parent-death watchdog stops an orphaned sender. A crash or interrupted record is unknown, never automatically resumed or promoted to installed. Watchdog hardware behavior was not injected in this validation.
- Results distinguish `notStarted`, `deviceStateUnknown`, and `transferredAwaitingConfirmation`. Host submitted bytes are not a resume offset, device acknowledgment or installed badge. Missing final ack, source changes, cancellation, invalid records and timeout remain conservative. No automatic retry, queue advance, object deletion, cleanup transfer or rollback.
- Records live under `~/Library/Application Support/SwitchShelf/MTPInstallAttempts/<UUID>/`: request, last intent/progress, worker result and independently verified supervisor result. Records contain local file paths; share cautiously.

## UI and packaging

`AppModel.swift`, `QueueView.swift`, `DeviceView.swift` and new `MTPInstallConfirmation.swift` expose the test flow. Exactly one selected file and a current passing local preflight are required. A separate sheet shows full path, exact byte count and intended target, with four unchecked confirmations covering file authority, actual MTP Install mode/target/settings, exclusive client and risk/result semantics. Only explicit final confirmation launches the helper. Queue mutations and inventory requests are blocked during transfer. Cancellation waits for the helper-exit verdict.

The host cannot set SD/NAND. The user must enter **MTP Install** and choose the destination inside sphaira. Seeing Install while ordinary MTP is enabled is insufficient. Transfer completion still requires checking the device's result; Games refresh is independent evidence, with local filename identity remaining a candidate.

`scripts/build-app.py` packages app/probe version **0.3.0 (3)**, required `libusb-1.0.0.dylib` **1.0.30**, its LGPL license/source notice, and re-signs the binaries. Runtime dependencies are bundled; no dependency/global setting was installed or changed. The pre-existing workspace `Assets/AppIcon.png` was used without editing or choosing a new icon.

## Validation and actual launch

- `swift test --skip RealNASScanTests`: **200 tests passed** — 189 Swift Testing (29 library, 8 domain, 112 device, 34 Backend, 6 BackendInstall) plus 11 XCTest protocol tests. **17 new tests** cover native fake-link framing, 30 packet-size/boundary combinations, fragmented/coalesced metadata, bad transactions/provider/datasets, create rejection/no retry, invalid native arguments without opening USB, file-review changes/unconfirmed input, lease/journal gates, durable state/replay preservation, and real local fixture child-process success/malformed result/cancellation/timeout/exit verification. A blocked progress callback is explicitly tested against the independent deadline. No test opens the physical USB device.
- Strict C `-Wall -Wextra -Werror` and `SS_VERIFY_SPHAIRA_USB_ABI` checks against the installed official libusb header passed.
- The initial 0.3-second process-timeout fixture could terminate Python before its PID marker was written. Increased that fixture to five seconds so it actually exercises a SIGTERM-ignoring child and verifies the killed PID is gone. Production timeouts were not changed to accommodate the test; final full regression passes.
- Release packaging and `codesign --verify --deep --strict build/SwitchShelf.app` passed. Bundled libusb was loaded without calling USB initialization/open. Invalid token worker invocation returned exit **64** without USB access.
- Checked that no installation helper was active before restarting only SwitchShelf. Rebuilt app launched at the bundle path as PID **92667**. Fresh AX tree and matching screenshot show **“sphaira 原生 MTP · 单文件测试”**, **“试验功能”**, and the existing **one plan / two included files / 5.42 GB**. The install action is correctly disabled before checking/selecting one file. Existing plan selections/notes were preserved; no confirmation or transfer action was taken.
- Local launch evidence: `build/native-mtp-queue-2026-10-25.png` and `.json`. The app remains running on the queue page. Real confirmation-sheet/transfer/device-result GUI acceptance is for the user's explicit manual test, not claimed here.

Artifacts:

- `build/SwitchShelf.app`
- `build/SwitchShelf-0.3.0-sphaira-mtp-test.zip` (3.1 MiB as displayed by local tools)
- ZIP SHA-256: `710d894fd2545bec9ceb34074abbf4cac5395132ede173e9d1053b1ec539b5f7`

## Remaining limits

Native exclusive interface ownership, the connected sphaira build's protocol behavior, actual installation result, large SMB throughput, unplug/reconnect recovery and real device-side cancellation are **not verified**. The system camera broker or another MTP client can still cause raw USB access/claim failure; software reports that error rather than killing a service or claiming success. Older/nonmatching sphaira capabilities/storage labels fail closed. This is local ad-hoc signing, not notarization.

Do not assume that the previous 29-record inventory validates this upload route. Before the manual test, follow `Docs/Guides/sphaira-mtp-install-test.md`. Each additional file/retry is a fresh explicit confirmation, not an automatic queue continuation.
