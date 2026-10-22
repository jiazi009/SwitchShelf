# SwitchShelf

Native macOS Switch game library and DBI device manager. Selected design: [liquid glass](output/design-demos/03-liquid-glass.png).

Requires macOS 26+, Apple Silicon and Swift 6/Xcode.
```sh
swift build
swift test
swift run SwitchShelf
swift run switchshelf-probe
python3 scripts/build-app.py
```
The local app is written to build/SwitchShelf.app. Native ImageCaptureCore is the default MTP path; the optional libmtp fallback can be bundled with --with-libmtp when required.

The NAS source /Volumes/switch 游戏包 is read-only. Initial hardware validation is discovery and MTP enumeration only. See [architecture](Docs/ARCHITECTURE.md), [plan](Docs/DEVELOPMENT_PLAN.md) and [full development document](SwitchShelf_开发文档.md).

