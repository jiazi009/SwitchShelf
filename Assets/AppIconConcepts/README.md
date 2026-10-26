# SwitchShelf icon concepts

Concepts 01–06 were generated with image_gen on 2026-10-25. `prompts.json` preserves the original prompts for 01–03; the later generation prompts were not saved here.

- 01: light glass cartridge shelf.
- 02: blue-violet library drawer.
- 03: dark glass shelf monogram.
- 04: console and library.
- 05: console, central folder and transfer arrows — **the user's selected direction**.
- 06: USB manager direction.
- 07: hand-authored, editable SVG simplification of 05, also rendered to a 1024px alpha PNG. One thumbstick per side replaces button clusters; the screen and tile have thin single rims; the folder and flat arrows have no glow. **Review candidate, not yet a final icon.**
- 08: further simplification of the selected sync direction. Cyan and coral rails, one folder with a single card, and two filled transfer arrows on the blue-to-violet tile. No button cluster, stacked folders, neon edge, or outer glow. SVG plus 1024px alpha PNG. **Selected on 2026-10-25 and copied to `Assets/AppIcon.png`.**

Packaging uses `Assets/AppIcon.png` by default, or `python3 scripts/build-app.py --icon /absolute/path/to/selected.png`. The builder creates all required ICNS sizes with macOS sips/iconutil and includes CFBundleIconFile before signing.
