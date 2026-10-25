# sphaira MTP installation software foundation — 2026-10-25

## Decision and scope

The user chose sphaira MTP for inventory and installation. Backend is deferred, not deleted or activated. Existing Backend/manifest changes were not edited or included in this work. No shared domain model changed, no worker was spawned, and no physical USB session or source-game read was performed in this checkpoint.

The already accepted Games inventory remains unchanged. This checkpoint does **not** claim a new live inventory read, installation, known device build, successful native upload or completed installation feature. Start remains disabled.

## Reviewed source baseline

- [sphaira 338348e74b6d278bc570a9be5373d25197bf6c8d](https://github.com/ITotalJustice/sphaira/tree/338348e74b6d278bc570a9be5373d25197bf6c8d): `sphaira/CMakeLists.txt` pins libhaze `f1c9c63`; `source/haze_helper.cpp`, `source/ui/menus/mtp_menu.cpp` and `source/ui/menus/install_stream_menu_base.cpp` establish installation mode/stream semantics.
- [R-YaTian/libhaze f1c9c632b5c615eabfb29a0dab89fedf606588e4](https://github.com/R-YaTian/libhaze/tree/f1c9c632b5c615eabfb29a0dab89fedf606588e4): `source/ptp_responder_mtp_operations.cpp::SendObjectPropList`, `source/ptp_responder_ptp_operations.cpp::SendObject`, and the responder operation switch establish the wire baseline.

These commits identify the reviewed upstream code, not the user's installed version. The device build remains unverified for installation compatibility.

Key findings:

1. Enabling MTP and showing Install does not activate installation. The Switch must enter **MTP Install**. The reviewed implementation rejects creation when install mode is disabled.
2. Install destination uses sphaira's own selected SD/user-storage setting. A host Install storage ID does not choose SD/NAND, and the queue picker is local intent only.
3. The source supports NSP, XCI, NSZ, XCZ and MSP. Extension validation does not validate package contents, identity or compatibility.
4. `SendObjectPropList` (`0x9808`) supplies storage/root, format, size high/low words and a filename property. `SendObject` (`0x100d`) is one sequential data phase. Its 32-bit data-header length saturates; the property-list size remains authoritative. No SendPartialObject/seek-based strategy is assumed.
5. The close callback disables the input stream while installation may still drain. The host can receive OK before the device installation finishes; the next create can return DeviceBusy. No host reply used here proves installation.

## Implemented files

- `Sources/SwitchShelfDevice/SphairaInstallPreflight.swift`: independent public metadata-only preparation API; current source mapping/availability/sizes, regular readable file, symlink rejection, PTP/UTF-8 filename bounds, supported extensions and case/Unicode-equivalent collision rejection. No content read, USB or authorization side effect.
- `Sources/SwitchShelfDevice/SphairaUploadCodec.swift`: internal upload-only encoder/strict response validator, 64-bit size, UTF-16 filename property, bounded header encoding. Existing inventory PTPCodec and its metadata-only allowlist are unchanged.
- `Sources/SwitchShelfDevice/SphairaMTPUpload.swift`: internal single-use/single-file streaming engine behind a fakeable raw transport. Requires same-session sphaira description, operations, Games and exactly one allowlisted Install storage. Continues the inspected session's transaction IDs, validates returned location/handle, bounds chunks to at most 4 MiB (1 MiB default), never retries/deletes/resumes. After any possible side effect, failure is deviceStateUnknown; even complete acknowledged transfer is transferredAwaitingConfirmation. Release failure is separately reported.
- `Sources/SwitchShelfDevice/SphairaPackageSource.swift`: internal allowlisted-root reader, read-only descriptor opened component-by-component with O_NOFOLLOW/O_CLOEXEC; nonblocking open avoids FIFO hangs before rejection. Pins inode/device/size/mtime/ctime and validates both the pinned descriptor and a symlink-free reopened name around bounded pread. No copying or hashing. Source close remains the owning helper/caller's responsibility.
- `Sources/SwitchShelfApp/AppModel.swift`: switched preparation from Backend types/service to sphaira; removed Backend import. Existing snapshot invalidation rules retained.
- `Sources/SwitchShelfApp/QueueView.swift`, `DeviceView.swift`: show the chosen route, MTP Install mode, device-side target selection and unfinished execution gate. No production send is reachable.
- Three new test files: `Tests/SwitchShelfDeviceTests/SphairaInstallPreflightTests.swift`, `SphairaMTPUploadTests.swift`, `SphairaPackageSourceTests.swift`.
- Updated architecture/plan and proposed `Docs/Tasks/sphaira-mtp-install-field-test.md`.

## Validation

`swift test --skip RealNASScanTests` passed: **172 Swift Testing tests** (29 library, 8 domain, 95 device, 34 Backend, 6 BackendInstall) plus **11 XCTest protocol tests**. Device adds **32 new tests**; parameterized cases provide additional combinations. Existing Backend tests were run as workspace regression only, not claimed as new sphaira implementation.

New coverage includes independent wire byte vectors; >4 GiB encoding without allocating a package; strict provider/storage/capability/location checks; continued transaction IDs; partial transport failures at every stage; DeviceBusy without retry; missing final acknowledgment; source mutation, missing/replaced files and same-size rewrites; before/during-transfer cancellation; wrong read lengths; close failure; repeated use; symlinked ancestors and parent substitution; source-root escape; FIFO/directory rejection; plan staleness and filename collisions. A real local temporary descriptor source feeds a **fake** transport and the source bytes remain unchanged. A sparse local temporary file exercises 64-bit pread at >4 GiB by reading only four bytes; it is not an SMB or device result.

Initial reader tests failed because Foundation standardization rewrote existing `/private/var` paths into the `/var` symlink. Fixed by keeping the reviewed path spelling and using POSIX canonical paths in fixtures; explicit component-by-component no-symlink checks now remain strict. Final regression passed.

`python3 scripts/build-app.py` passed and `codesign --verify --deep --strict build/SwitchShelf.app` passed. No unconfirmed icon was selected. No new live GUI acceptance was performed. `git diff --check` passed before completion.

## Outstanding gates — do not imply production installation support

- No native upload transport exists yet. The ImageCaptureCore inventory path's `outData: Data` must not be repurposed by materializing whole game packages. Verify bounded raw/native streaming and packet/ZLP behavior first; the raw response codec requires preserved transaction IDs, unlike ImageCaptureCore's reassignment.
- Integrate same-session metadata inspection and DeviceLease **before** physical open, retaining ownership through verified close/process exit. The transport contract documents this requirement; fake transports do not prove it. Do not kill ptpcamerad or other system services.
- Add a process-isolated helper with hard USB/SMB deadlines, positive exit verification, durable conservative attempt state and explicit reviewed file/target confirmation. The current async engine/source reader alone has no hard deadline or crash journal. Blocking filesystem operations must stay out of UI, but a background actor is not a hard-timeout guarantee.
- Preflight reflects only metadata at check time and does not pin identity through later execution. The future confirmation/helper boundary must revalidate the reviewed source mapping/fingerprint; no transfer should be authorized by `isPrepared` alone.
- Review the proposed field-test gate and explicitly select one authorized package and device-side destination/settings before any physical installation. No file or target is selected by this report.
- Preserve conservative installation badges. Future transfer acknowledgment and user/device result confirmation are separate from refreshed Games evidence; local filename-only package identity is still a candidate.
