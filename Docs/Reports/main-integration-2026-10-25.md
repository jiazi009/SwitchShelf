# Main branch integration — 2026-10-25

## Requested result

Switch the current repository to `main` and absorb all existing local feature branches. No remote is configured. The two source branches were `codex/codegraph-init` and `jiazi009/game-cover-loading`; the latter owns a separate clean worktree at `/Users/jiazi/orca/workspaces/SwitchShelf/game-cover-loading`.

Integration used commit application, not a branch merge. No branch/worktree was deleted, force-updated or modified on another worker's behalf. No global setting was changed, agent spawned, source game touched, USB session opened, or installation retried.

## Integrated commits

Starting `main`: `6cf930e`.

- Applied the linear `codex/codegraph-init` sequence with `git cherry-pick --ff`, preserving its original commit IDs: `d650594`, `c6c043a`, `7458fd3`, `3584311`, `d069690`. This includes sphaira Games inventory, icon packaging support, local preparation, and the native isolated single-file MTP test flow.
- Applied cover branch `1d306ae` as **`77da40b`** with `git cherry-pick -x`, retaining its original author and source-commit provenance. Its eight files add local sidecar selection, image thumbnails/cache, Nlib candidate-ID icon lookup, UI rendering and seven cover-loading tests. No manifest/domain change or manual conflict resolution was needed.
- `git log --cherry-pick --right-only --no-merges main...<source-branch>` returns no remaining unique feature patches for either source branch. The cover branch is patch-equivalent rather than recorded as an ancestry merge; its original ref and worktree are intentionally retained.

## Pre-existing uncommitted work preserved

Before switching branches, recorded content SHA-256/file modes for **17 existing dirty files**, saved the tracked binary diff, retained the previous main ref under `refs/backups/`, and stashed tracked/untracked work. This includes the confirmed 08 app-icon assets/README changes and the unfinished Backend helper/manifest/protocol/USB/test/report changes.

After integration, applied the exact saved stash onto `main`, without committing those unrelated changes. Git normalized eight untracked files from mode 0600 to 0644 during restore; verification caught this and restored their original captured modes. All 17 files' contents and file modes, and the tracked binary diff, now match the pre-integration checkpoint. No data was discarded.

- Retained backup stash: `556c9718270c961923501271a016dfde92a8c561` (already applied; do not apply it again).
- Local checkpoint, original manifest/diff and test logs: `/tmp/SwitchShelf-main-integration.5CG66g/`.
- `main` is deliberately not clean: the same pre-existing uncommitted work remains available for its owner to review/commit separately.

## Validation

1. With all pre-existing dirty work safely stashed, tested the **committed main contents alone**:
   - `swift test --skip RealNASScanTests`: **200 tests passed** — 190 Swift Testing (36 library, 8 domain, 112 device, 34 Backend) plus 10 XCTest protocol tests.
   - `swift build -c release --product SwitchShelf`: passed.
2. After restoring the original dirty work and verifying its hashes/modes:
   - `swift test --skip RealNASScanTests`: **207 tests passed** — 196 Swift Testing (36 library, 8 domain, 112 device, 34 Backend, 6 BackendInstall) plus 11 XCTest protocol tests.
   - `git diff --check`: passed.

Cover HTTP tests use an injected URLProtocol, not the live provider. No new NAS scan, live cover download, device installation or GUI acceptance was claimed. The user previously reported sphaira itself displayed installation success; this integration did not repeat or broaden that physical test.

The previously packaged `.app`/ZIP and running app were not rebuilt/restarted by this branch-only operation. Source integration does not make an already-running executable pick up the new cover-loading code; packaging/running that new combination is a separate next action if requested.
