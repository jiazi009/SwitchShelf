# Release review and physical acceptance — 2026-10-28–29

Version 0.3.4 (5) uses libusb for inventory, installation and post-install verification. ImageCaptureCore and libmtp routes have been removed. This is a locally signed release candidate, not a notarized public distribution.

## Findings and fixes

- A successful upload released the host USB interface without PTP CloseSession. The sender now closes a healthy completed/refused-create session before releasing the interface; incomplete/uncertain data phases are never interrupted by an injected close. Close failures remain explicit.
- DeviceBusy retries previously ignored failed release. Retrying a zero-byte explicit refusal now also requires verified release; uncertain writes are never repeated.
- Cancelling inventory previously waited for the detached helper deadline. A private cancellation marker now asks the supervisor to stop and reap its direct USB worker. Unverified exit, signaled/malformed supervisor output and inconsistent results fence future reads and sends.
- The first integrated real helper run exposed a Swift 6 MainActor assertion in the new parent-watch DispatchSource callback. An explicit Sendable handler fixed it. Real Debug and Release supervisor/worker launches are now smoke-tested, alongside fake-process tests.
- Verification previously repeatedly read Games for six minutes, hid errors, accepted whole-game assessments rather than the selected files, and restored transfer states using filenames alone. It now binds automatic verification to the sending USB registry entry, checks a fresh complete inventory against this batch's source paths, sizes, targets, selected Title IDs/kinds/raw versions, stops after four attempts, retains actionable errors, and does not reconstruct sends from filename-only history.
- A successful explicit manual read can finish a sent batch after the device refreshes its projection. An automatic background read publishes inventory without attaching that old batch to another device.
- Confirmed items show success for 600 ms, then exit with a trailing/fade transition and are removed from the plan. Reduce Motion uses opacity; disabled animation is immediate. Removal is saved immediately before unlocking the plan. Unconfirmed/partial/cancelled items remain.
- Manual device controls, installation preparation and monitoring now respect verification/file-operation locks. USB discovery starts independently of slow SMB availability checks.

## Games cache limitation, reproduced

The device accepted the Goose Game base and update, reported success on its own screen (confirmed directly by the user), and released both host sessions normally. Repeated new PTP sessions still exposed the old 8-directory/22-record Games list. After the user exited/reopened sphaira and enabled MTP, the device exposed 9 directories/24 records. A manual read in the same running SwitchShelf then confirmed the two selected records and cleared the staged item; the saved plan is `[]`.

The pinned upstream [Games filesystem](https://github.com/NaGaa95/sphaira/blob/338348e74b6d278bc570a9be5373d25197bf6c8d/sphaira/source/utils/devoptab_game.cpp) caches mounted entries and per-title metadata. Opening another PTP session resets object handles, not that Games mount. This explains the observed behavior, but a reported version string does not prove the connected binary exactly matches that source. There is no reviewed standard read-only command here that forces the underlying Games cache to refresh. The app therefore retains the unconfirmed plan and offers a manual recheck instead of repeatedly reconnecting or resending.

## Authorized physical reinstall

The user deleted Goose Game and explicitly requested a fresh installation/recognition run. The baseline inventory was complete with 22 records and no selected Goose IDs. Only the selected source package bytes were streamed, without modification, hashing or copying on the NAS.

| Package | Bytes | Request |
|---|---:|---|
| Goose Game base, `010082400BCC6000`, v0 | 834,297,609 | `ED719257-BD20-4B3D-8C7D-67BAA89E1110` |
| Update 1.1.2, `010082400BCC6800`, raw v458752 | 375,633,682 | `57459E9F-343A-4F79-868F-26E9E7AA3052` |

Both reports confirm all bytes submitted, `transferredAwaitingConfirmation`, verified release and independently verified helper exit. The plan target was SD; the device remains authoritative for its actual destination. After the user's device-side refresh, the 2026-10-29 20:28:54 +08 inventory contained the explicit BASE v0 and UPD v458752 records. The live app displayed installation success, the Goose card displayed installed, and staging was 0 items/0 bytes with start disabled. Local package identity remains filename-derived; no cryptographic package-byte identity claim is made.

Structured evidence: [release-review-2026-10-29-evidence.json](release-review-2026-10-29-evidence.json). Full local logs/receipts are under `output/diagnostics/release-review-2026-10-28/` (ignored by Git). No device objects or saves were deleted by the agent.

## Actual MTP information fields

Final read-only DeviceInfo/GetStorageInfo observation: 2026-10-29 20:31:42 +08, with verified CloseSession/host release. Serial and volume labels were not retained.

- Manufacturer/model: Nintendo / Nintendo Switch.
- DeviceVersion: `Sphaira/1.0.8 HOS/19.0.1`; this directly provides sphaira and HOS versions, not an Atmosphère version.
- Supported device properties: empty. Battery, temperature, nickname and Atmosphère version were not provided by this observation.
- 17 supported operation codes, 6 event codes, vendor extension ID 6/version 100/description `microsoft.com: 1.0;`, object formats 0x3000 and 0x3001.

| Reported entry | Capacity bytes | Free bytes | Decimal GB capacity / free |
|---|---:|---:|---|
| microSD card | 126,420,779,008 | 55,641,833,472 | 126.42 / 55.64 |
| Contents (User) | 27,903,639,552 | 3,061,039,104 | 27.90 / 3.06 |
| Contents (System) | 2,683,027,456 | 1,025,916,928 | 2.68 / 1.03 |

The two Contents entries retain the service's names; they are not independently measured hardware capacity. Games, Mounts and DevNull each report 256 GiB virtual capacity and must not be summed or shown as physical disks. These fields were inspected by a separate bounded diagnostic; the existing device UI does not yet render all of them.

## Validation and limits

- Final offline suite: 286 Swift Testing tests plus 11 XCTest tests, all passed; real NAS scanning excluded.
- Current-source AppModel lifecycle harness: 34 assertions, including selected versions, partial/historical rejection, device changes, cancellation, cross-operation fencing, delayed removal, persistence and automatic-vs-manual confirmation.
- Real helper runtime: 10 Debug and 10 Release discovery launches; retired route rejection, pre-launch cancellation, no ImageCaptureCore linkage.
- 51 cover checks, 24 offscreen layouts, 64 native state/size cases and 28 native content snapshots. All source/image fingerprints and x/y geometry checks pass. One dark/reduced-motion run hit the fixture's 2-second settling timeout; an unchanged-source rerun passed. That first failed log is retained, and no production geometry fix is claimed from it.
- Release bundle build and strict deep signature verification passed. `codesign` reports ad-hoc/no Team ID. Developer ID signing/notarization remain required before public distribution.
- Actual sender completion, cached Games behavior, device-mode interruption, refreshed recognition and saved staging removal were verified on this connected Switch. Other server builds, long SMB stalls, interrupted large-file installs and performance/frame-rate acceptance are not established by these results.
