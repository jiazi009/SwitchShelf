# SwitchShelf

Native macOS Switch game library with read-only sphaira / DBI MTP inventory. Selected design: [liquid glass](output/design-demos/03-liquid-glass.png).

## 界面截图

以下截图采集自 2026-10-30 正在运行的 SwitchShelf 0.3.6，展示主要工作界面。采集时 USB 与 FTP 均未连接，设备内容目录展示的是历史缓存，不代表设备当前安装状态。点击图片可查看原图。

**游戏库 · 网格视图** — 浏览游戏封面、内容类型与容量，通过搜索、筛选和排序定位游戏。

![游戏库网格视图与安装待选区](Docs/Screenshots/01-library-grid.jpg)

<details>
<summary>游戏库 · 列表视图</summary>

列表集中展示游戏名称、本体 / 更新 / DLC、文件数量、来源和容量。

![游戏库列表视图](Docs/Screenshots/02-library-list.jpg)

</details>

<details>
<summary>游戏详情与安装待选</summary>

详情浮层展示封面、匹配信息与安装状态依据；点击卡片可加入右侧待选区，展开选择本体、更新和 DLC，并查看计划目标与总容量。截图中的开始安装按钮因设备未连接而禁用。

![游戏详情浮层与历史清单状态](Docs/Screenshots/03-game-details.jpg)

![安装待选区与本体更新 DLC 文件选择](Docs/Screenshots/04-installation-staging.jpg)

</details>

<details>
<summary>我的 Switch · 设备信息与内容目录</summary>

设备页展示 USB 检测、清单会话、存储入口及完整性信息；内容目录按游戏分组列出本体、更新和 DLC，支持搜索。以下为未连接设备时显示的历史清单。

![我的 Switch 设备概览与存储信息](Docs/Screenshots/05-device.jpg)

![设备历史内容目录与游戏分组](Docs/Screenshots/06-inventory.jpg)

</details>

<details>
<summary>无线连接 · DBI FTP</summary>

填写主机与端口，查看连接指引和只读探测结果。截图为未连接状态。

![无线连接与 DBI FTP 主机设置](Docs/Screenshots/07-wireless.jpg)

</details>

<details>
<summary>文件管理</summary>

设备存储、目录导航、搜索排序及单文件上传 / 下载入口。截图为等待设备连接状态。

![文件管理等待设备连接](Docs/Screenshots/08-file-manager.jpg)

</details>

<details>
<summary>相册截图</summary>

相册搜索、图片预览与下载入口。截图为等待设备连接状态。

![相册截图搜索预览与下载界面](Docs/Screenshots/09-album.jpg)

</details>

<details>
<summary>维护与设置</summary>

维护页汇总本地游戏、来源、缓存、安装待选和扫描问题；设置页提供启动扫描选项、本地数据入口与版本信息。

![维护页面的缓存来源与扫描诊断](Docs/Screenshots/10-maintenance.jpg)

![设置页面的扫描选项本地数据与版本](Docs/Screenshots/11-settings.jpg)

</details>

## Build and usage

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

