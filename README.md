# SwitchShelf

Native macOS Switch game library with read-only sphaira / DBI MTP inventory. Selected design: [liquid glass](output/design-demos/03-liquid-glass.png).

Requires macOS 26+, Apple Silicon and Swift 6/Xcode.
```sh
swift build
swift test --skip RealNASScanTests
swift run SwitchShelf
swift run switchshelf-probe
python3 scripts/build-app.py
```
The local app is written to build/SwitchShelf.app. Device inventory and installation both use libusb; the app bundles its runtime. ImageCaptureCore and libmtp connection routes are no longer available.

For an installed-content inventory, enable MTP and the `Games` storage in sphaira, or use DBI's `Run MTP responder` with `Installed games` exposed. Fully quit OpenMTP before reading in SwitchShelf. The device page distinguishes USB detection, successful MTP communication and inventory completeness, and shows the reported storage names, game-directory count and base/update/DLC records. Only recognized inventory storages are traversed; raw content, mounts, saves, installation and speed-test storages are not scanned.

The sidebar page 无线连接 is a separate DBI FTP client for the documented SD file-access port 5000. Port 6000 is the documented install port and is refused without a socket. A successful `LIST` is directory text, not an installed-game inventory. That client is covered by fixtures and a loopback server only; it has not been verified against a Switch. USB MTP inventory and the sphaira install test stay in place. While a Wi-Fi session is connecting or connected, USB discovery and the install test are skipped so the two sessions do not overlap.

The bounded CLI equivalent is `build/SwitchShelf.app/Contents/MacOS/switchshelf-probe inventory --transport libusb --timeout 90 --json` (run only when the app and other MTP clients are not reading). Exit 2 means incomplete coverage, not a disconnected or empty console. `storages` lists descriptions without traversing games. Reported MTP storage names are a capability observation, not proof of the server's version or console environment. Filename-derived identities can be compared by Title ID, content kind and explicit raw version; the UI explains that package bytes remain unverified. Cached historical inventories never establish a current installation state.

Icon concepts are in [Assets/AppIconConcepts](Assets/AppIconConcepts). The selected bundle icon is concept 08, copied to `Assets/AppIcon.png`. `python3 scripts/build-app.py` turns that PNG into the macOS ICNS sizes. Override with `--icon /absolute/path/to/selected.png` if needed. Live read-only acceptance and remaining limits: [sphaira inventory report](Docs/Reports/sphaira-inventory-acceptance-2026-10-25.md).

The NAS source /Volumes/switch 游戏包 is read-only. User-authorized installation streams package bytes without modifying source files. The Goose Game base/update reinstall and post-install recognition were exercised on the connected Switch; see [release review](Docs/Reports/release-review-2026-10-29.md). Games may remain cached until sphaira is restarted; the app stops after bounded checks and offers an explicit read-only recheck instead of resending. See [architecture](Docs/ARCHITECTURE.md), [plan](Docs/DEVELOPMENT_PLAN.md) and [full development document](SwitchShelf_开发文档.md).

