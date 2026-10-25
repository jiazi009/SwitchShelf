# SwitchShelf icon concepts

Concepts 01–06 were generated with image_gen on 2026-10-25. `prompts.json` preserves the original prompts for 01–03; the later generation prompts were not saved here.

- 01: light glass cartridge shelf.
- 02: blue-violet library drawer.
- 03: dark glass shelf monogram.
- 04: console and library.
- 05: console, central folder and transfer arrows — **the user's selected direction**.
- 06: USB manager direction.
- 07: hand-authored, editable SVG simplification of 05, also rendered to a 1024px alpha PNG. One thumbstick per side replaces button clusters; the screen and tile have thin single rims; the folder and flat arrows have no glow. **Review candidate, not yet a final icon.**

Packaging accepts `python3 scripts/build-app.py --icon /absolute/path/to/selected.png`, or `Assets/AppIcon.png` as the selected default. The builder creates all required ICNS sizes with macOS sips/iconutil and includes CFBundleIconFile before signing. Do not copy 07 to `Assets/AppIcon.png` or package with `--icon` before the user confirms it.
