# sphaira MTP installation — proposed field-test gate

Status: **not authorized, not scheduled, not run**. The user's route selection authorizes software development, not an arbitrary source-game read or device installation. Backend testing is not part of this route.

## Software prerequisites

- Native bounded streaming adapter verified without hardware first: one SendObject data phase, packet/ZLP handling, 64-bit size, no whole-file Data/copy/hash, no partial-object edit or seek.
- Same opened session supplies DeviceInfo description/capabilities, Games and one allowlisted Install storage; no cached handles, VID/PID-only provider assertion or implicit fallback to microSD/Contents.
- Machine-wide DeviceLease acquired before physical open; no inventory/Backend/second upload session concurrently. Third-party clients require user exit; do not kill system services.
- Process-isolated USB/SMB hard deadlines with positive child-exit verification and conservative uncertain-release fencing. Caller cancellation alone does not prove native I/O stopped.
- Durable attempt record written before first side effect; interrupted/restarted attempts remain unknown, never automatic retry/resume. Record submitted bytes separately from device acknowledgment and installation evidence.
- Execution-time source mapping/fingerprint revalidation, visible confirmation showing exact file, size and intended target. Preflight is not authorization or package-identity verification.

## Required user/coordinator review

All fields are currently **unknown/unselected**:

- One specific, authorized, preferably small test package: exact source path, filename and size. Do not infer approval from the library, queue or source volume.
- Current device sphaira version and actual MTP Install UI, installation settings and destination (SD or user NAND). Local queue intent cannot set this destination.
- Existing installed state and expected outcome; a small update/DLC is not automatically safe or approved.
- Agreed success evidence and recovery/stop plan. Do not delete objects, modify saves, format storage or uninstall content as cleanup.

## Reviewed run sequence (only after the prerequisites and review)

1. Quit other MTP clients. Keep the selected console connected and enter sphaira **MTP Install**; confirm target/settings on the device.
2. Show exactly one selected file and explicit confirmation. Save the pre-transfer record, acquire exclusive lease, and inspect the same session's identity/capabilities/storages.
3. Send one filename property list with the 64-bit size, then stream that file sequentially with bounded reads. Any rejection, timeout, cancellation, disconnect or source change stops the run without retry/deletion.
4. Record host outcome, final PTP response and verified process/session release separately. Even complete SendObject + OK means **transferred, awaiting device confirmation**.
5. User confirms sphaira's install result. Only after release, a separate read-only Games refresh may provide independent content-level evidence. Filename-only local identities remain candidates. Do not turn absence or partial inventory into failure/success proof.
6. Report exact observed behavior and unresolved outcomes. Additional files, retries and failure-injection hardware tests require further review rather than being implied by the first test.
