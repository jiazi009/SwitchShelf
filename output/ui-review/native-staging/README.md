# Current installation-staging native-window evidence

These are **synthetic data in a visible, real production SwiftUI WindowGroup**, not the user's library/device and not desktop screenshots. Only model/bootstrap/defaults are isolated; production view sources and native scene sizing are retained.

Reproduce:

```sh
swift build
scripts/verify-ui-layout.sh --empty-library-window
scripts/verify-ui-layout.sh --empty-library-window --dark
scripts/verify-ui-layout.sh --empty-library-window --reduce-motion
scripts/verify-ui-layout.sh --empty-library-window --dark --reduce-motion
scripts/verify-ui-layout.sh
python3 scripts/verify-ui-evidence.py
```

Each variant contains 16 state/size records: empty, populated grid, populated list, and expanded ambiguous update; each at requested content sizes 960×640, 1280×820, 1516×809 and 1276×1410. Native titlebar space is additional (e.g. the 960×640 content request yields a 960×692 full native content-view snapshot). JSON records the actual viewport/window frame separately.

Checks cover **both axes**, the 320-point sidebar, always-visible start button, populated staged cards/titles/remove controls, library viewport, first visible source card/row, info icon, and list cover/byte fields. Ordinary below-viewport scrolling content is not misreported as clipping. Native geometry must settle inside the viewport within a bounded 2 seconds before assertions and captures.

Each variant retains 8 PNGs: empty/narrow, populated grid/narrow+wide, populated list/narrow, expanded ambiguous update/narrow, independent detail popovers for grid/list, and the visible unconfirmed installation review sheet. Capture uses the active native window's own `NSView.cacheDisplay`, with captured alpha composited over its effective native window background. It does not invent controls or change system permissions. AppKit materials/foregrounds and GPU animation frames are not guaranteed pixel-identical to a desktop capture.

`manifest.json` stores production Swift source SHA-256 values and image hashes. `scripts/verify-ui-evidence.py` rejects stale sources/images, missing empty/populated/narrow cases, or out-of-viewport x/y geometry. The separate `../layout/` directory retains all 24 current-source offscreen layouts and their hashes; do not restore old images after running verification.

No bootstrap, real USB open, NAS package read or installation occurs in this harness. The three-byte package-named files and USB descriptors used for the review-sheet test are explicitly fixtures, not evidence of a real package or device. Four consent boxes stay unchecked and no confirmation is sent. Actual test-App startup/visibility and the external AX limitation are documented in `Docs/Reports/install-staging-redesign-2026-10-28.md`.
