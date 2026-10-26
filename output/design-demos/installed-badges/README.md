# Installed-game badge concepts

Selected direction: **B**, implemented in `GameViews.swift`. Actual SwiftUI fixture renders: [light](implementation/B-swiftui-light.png), [dark](implementation/B-swiftui-dark.png). Implementation and validation: `Docs/Reports/installed-badges-b.md`.

These three image-generated UI concepts use only the live SwitchShelf screenshot captured on 2026-10-26 (Asia/Shanghai), not the earlier design demos.

- Branch: `codex/installed-game-badges`
- Base commit: `9c81bec`
- Reference: `00-live-app-reference.png`
- Generator: built-in `image_gen`, one call per variant.
- Concept-generation scope (commit `16839f2`): design images only. The selected B implementation is documented above.
- Example “已安装” labels on 1-2-Switch and 路易吉鬼屋 3 are mock states. The screenshot actually reports 设备未检测; these concepts do not establish any game's installation state.

| Concept | Treatment |
| --- | --- |
| [A](01-cover-pill.png) | Compact green checkmark capsule at the cover's top left |
| [B](02-title-inline.png) | Quiet green checkmark and installed text above the title inside its dark cover area |
| [C](03-metadata-status.png) | Checkmark and installed text in the metadata row below the cover; file size stays at right |

The new worktree starts from the current committed HEAD. Existing uncommitted work in the original checkout is preserved there.

## Exact generation prompts

### A · 封面胶囊

```text
Use case: ui-mockup.
Asset type: high-fidelity native macOS SwiftUI app screenshot, design variation for SwitchShelf.
Input image: the attached image is the ONLY edit target and visual reference. It is a fresh actual screenshot of the user's latest running app. Preserve this screenshot's current layout exactly. DO NOT use or reconstruct any previous old design reference.
Primary request: add a clear installed-game indicator to the existing game library. The output must look like the SAME real current application, with only the requested indicator changed.
Invariants: same complete app window, exact 3-column cover grid, same left translucent lavender sidebar, same neutral light canvas, same empty right detail inspector, same toolbar/search/filter controls, same traffic/control icons, same game covers and Chinese titles, same card proportions, same crop and dimensions/aspect ratio. Keep the titles over the bottom of the cover cards and preserve their current dark artwork-derived backgrounds. Keep everything crisp, realistic native macOS styling with restrained green as the installation accent, no marketing redesign, no new panels, no extraneous callouts, no device claims. No new titlebar or desktop background.
Mock data: Only the top-left card "1-2-Switch" and bottom-right card "路易吉鬼屋 3" should display installed state; the other four visible cards must have no installed badge. These are conceptual sample states, not observed device results. Preserve the screenshot's existing "设备未检测" control, counts and all other text unchanged.
Typography: exact Chinese text "已安装", using native PingFang/SF-like fonts. Both checkmark symbol and text must communicate state, never color alone.

VARIANT A — cover-corner capsule. Add a compact solid forest-green pill with a small white circular checkmark and white exact text "已安装", tucked inside the TOP LEFT of each of the two sample installed covers, with 9px inset. Subtle native soft shadow, 22px pill height, careful optical padding. It sits on the artwork without moving anything. Visually polished and readable over both light and dark cover artwork. Do not put any installed indicator below the covers or next to their titles. Return the entire edited app screenshot, not a crop or concept board.
```

### B · 标题旁标识

```text
Use case: ui-mockup.
Asset type: high-fidelity native macOS SwiftUI app screenshot, design variation for SwitchShelf.
Input image: the attached image is the ONLY edit target and visual reference. It is a fresh actual screenshot of the user's latest running app. Preserve this screenshot's current layout exactly. DO NOT use or reconstruct any previous old design reference.
Primary request: add a clear installed-game indicator to the existing game library. The output must look like the SAME real current application, with only the requested indicator changed.
Invariants: same complete app window, exact 3-column cover grid, same left translucent lavender sidebar, same neutral light canvas, same empty right detail inspector, same toolbar/search/filter controls, same traffic/control icons, same game covers and Chinese titles, same card proportions, same crop and dimensions/aspect ratio. Keep the titles over the bottom of the cover cards and preserve their current dark artwork-derived backgrounds. Keep everything crisp, realistic native macOS styling with restrained green as the installation accent, no marketing redesign, no new panels, no extraneous callouts, no device claims. No new titlebar or desktop background.
Mock data: Only the top-left card "1-2-Switch" and bottom-right card "路易吉鬼屋 3" should display installed state; the other four visible cards must have no installed badge. These are conceptual sample states, not observed device results. Preserve the screenshot's existing "设备未检测" control, counts and all other text unchanged.
Typography: exact Chinese text "已安装", using native PingFang/SF-like fonts. Both checkmark symbol and text must communicate state, never color alone.

VARIANT B — quiet inline title indicator. In the existing dark title zone at the BOTTOM of each of the two sample installed covers, add a compact green checkmark seal plus exact text "已安装" in a small mint-green native font, on one short line directly ABOVE the existing white title. Slightly increase the dark gradient behind only this tiny text area for contrast, but keep the covers and card dimensions and titles in their current position. No pill or capsule background, no top-corner badge. Make the indicator feel integrated and calm, clearly different from a floating badge. Other cards remain unchanged. Return the entire edited app screenshot, not a crop or concept board.
```

### C · 封面下状态行

```text
Use case: ui-mockup.
Asset type: high-fidelity native macOS SwiftUI app screenshot, design variation for SwitchShelf.
Input image: the attached image is the ONLY edit target and visual reference. It is a fresh actual screenshot of the user's latest running app. Preserve this screenshot's current layout exactly. DO NOT use or reconstruct any previous old design reference.
Primary request: add a clear installed-game indicator to the existing game library. The output must look like the SAME real current application, with only the requested indicator changed.
Invariants: same complete app window, exact 3-column cover grid, same left translucent lavender sidebar, same neutral light canvas, same empty right detail inspector, same toolbar/search/filter controls, same traffic/control icons, same game covers and Chinese titles, same card proportions, same crop and dimensions/aspect ratio. Keep the titles over the bottom of the cover cards and preserve their current dark artwork-derived backgrounds. Keep everything crisp, realistic native macOS styling with restrained green as the installation accent, no marketing redesign, no new panels, no extraneous callouts, no device claims. No new titlebar or desktop background.
Mock data: Only the top-left card "1-2-Switch" and bottom-right card "路易吉鬼屋 3" should display installed state; the other four visible cards must have no installed badge. These are conceptual sample states, not observed device results. Preserve the screenshot's existing "设备未检测" control, counts and all other text unchanged.
Typography: exact Chinese text "已安装", using native PingFang/SF-like fonts. Both checkmark symbol and text must communicate state, never color alone.

VARIANT C — metadata status row. Leave ALL cover artwork and the white titles on covers entirely untouched; add NO overlay on the artwork. In the existing metadata line immediately BELOW each of the two sample installed cards, place a green circular checkmark icon with exact green text "已安装" aligned to the LEFT; keep the file size aligned right in that same line. For those two cards only, replace the left metadata text "本体 · 更新" or "本体 · 更新 · 2 个 DLC" with the checkmark and "已安装" so no extra height is added and grid alignment is perfectly preserved. Other four cards retain original metadata and no badge. Use a medium-weight 11px native font, no pill background. Return the entire edited app screenshot, not a crop or concept board.
```

## Review and validation

All three generated outputs were visually reviewed: each retains the latest screenshot's three-column library, six game covers, sidebar, toolbar and empty inspector; each marks only the two intended sample cards. “已安装” text and checkmarks are legible in each variant. Image generation can subtly redraw artwork and small incidental text; these are design concepts rather than exact app captures. Only 00-live-app-reference.png is the unmodified live capture.

The concept-generation stage changed only images and documentation, so no runtime tests were needed at that stage. The subsequent B implementation passed build, state-assessment tests and SwiftUI visual checks; see its implementation report above. No game-source or device operations were performed.
