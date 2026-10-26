# Cover presentation and UI review — 2026-10-26

Branch: `codex/cover-ui-review`. The user approved the generated cover preview and explicitly authorized three supervised subagents for secondary-page fixes, cover validation, and independent review. All changes were integrated in the shared checkout; existing manifest, backend and icon work was preserved.

## Changes

- Grid covers keep square artwork full width above a seamless, artwork-derived dark gradient. The game title appears once, inside the lower dark region; package types and size stay below the card. Missing artwork remains an explicitly labeled placeholder.
- List rows use 44×44 artwork; queue thumbnails use 50×50 artwork, and the inspector displays the original square composition. Small thumbnails no longer include miniature poster titles or colored mats.
- A bounded 24×24 sRGB sample derives the cover tint. Sampling is cached with remote artwork; dark color channels keep white title text readable. Local artwork revalidates metadata before reusing disk thumbnails.
- Search, filter menus, layout switch and size control share a 32-point height. Native menu chrome no longer compresses filter labels into short pills; accessibility labels are combined once per menu. The library header adapts through additional rows when the middle column is narrow.
- The add-folder action uses the native prominent glass style without a forced foreground color, allowing active/inactive text contrast. Its capsule border matches the neighboring device-status capsule.
- The sidebar loads the packaged `CFBundleIconFile` artwork, preserving its colors and shape, instead of drawing a generic controller mark.
- Cover badges share an adaptive container to avoid collisions at the smallest card size. An empty game no longer claims an offline source merely because `allSatisfy` on an empty array is true.
- Solid status badges use a dark fill that supports white text in both appearances, including the formerly pale offline badge in dark mode.
- Queue actions adapt between horizontal and vertical arrangements; maintenance statistics use adaptive columns. Long device names, package names, paths and notes are handled without pushing fixed metadata out of their rows.
- The installation confirmation view scrolls its long content while keeping confirm/cancel controls available. Confirmation conditions and transfer behavior were not changed. Settings now describe the existing experimental single-file workflow accurately.

## Thumbnail cache

`CoverThumbnailStore` stores one metadata-fingerprinted record per URL, retaining a bounded disk budget and refusing symbolic links. The UI can retrieve its last derived local thumbnail when source metadata is unavailable. An online changed/corrupt source does not fall back to stale data.

Legacy `SCVR` entries migrate on the next successful online exact lookup. A first upgrade while already offline cannot reverse the old metadata-dependent hash; that old cover becomes available offline after one online migration.

## Verification

- `swift test --skip RealNASScanTests`: **213 passed** (202 Swift Testing cases across the five targets, plus 11 XCTest cases). This includes 13 cover-loading tests, with six new cache regressions. Real NAS tests were skipped; device/install coverage used fixtures and local test files.
- `bash scripts/verify-cover-presentation.sh`: **51 checks passed**, covering color identity, white/black/gray and alpha handling, extreme aspect ratios, logos/letterboxing and white-text contrast.
- Release packaging through `python3 scripts/build-app.py` and strict ad-hoc signature verification passed. No manifest or shared domain changes were needed for this UI work.
- Live native-app checks used the real cached 16-game library: grid/list switching, square list artwork, gradients and long titles, search, selection/inspector, add-folder chooser and cancellation, empty queue disabled controls, maintenance and settings. The final add-folder capsule was checked alongside the device pill after rebuilding and restarting the app. Device-page navigation performed ordinary read-only USB candidate discovery; no inventory request or installation was initiated.
- The independent reviewer rechecked the final view and cache changes and found no additional blocking issue.

The first sandboxed regression run waited inside macOS LaunchServices during local fixture directory enumeration. It was stopped after a process sample; the full run then passed with system-service access. This was not a cover-cache lock failure.

## Layout artifacts and limits

`scripts/verify-ui-layout.sh` compiles copies of the current production views into an isolated fixture harness, with temporary model/cache paths and a separate defaults domain. It does not run the production bootstrap, scan a real source, or open a device session. **24 PNGs** and a machine-readable manifest were generated under `output/ui-review/layout/` for 960×640 and 1280×820 layouts in light/dark appearances, including the 120-point compact grid. All requested dimensions were asserted; representative images were visually checked by both the layout worker and coordinator.

Those captures verify geometry and text wrapping. Offscreen AppKit controls, glass materials and native appearance colors have rendering limitations; they are not equivalent to live system-material verification. A separately bundled instance of the `--live-dark` fixture window was also inspected with native screenshots: menu text and inspector colors render correctly in the actual dark window. The formal bundled icon was checked in the actual app, not the unbundled harness. Real SMB disconnects and physical installation remain outside this UI task.

No Orca run/task lifecycle was injected into this Codex chat; this report and the final response record the files, checks, commit and limitations.
