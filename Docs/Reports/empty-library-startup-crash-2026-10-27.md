# 移除最后一个来源后的启动崩溃 — 2026-10-27

## 证据和原因

用户移除 NAS 来源后，游戏库数据库中 sources/games 均为 0；随后两次启动约 2 秒内崩溃。系统日志 `SwitchShelf-2026-10-27-231150.ips` 与 `SwitchShelf-2026-10-27-231200.ips` 的主线程均为 AppKit/SwiftUI 布局异常：`NSWindow _postWindowNeedsUpdateConstraints`、`NSHostingView`。统一日志明确报告窗口的约束更新次数超过视图数；不是 SQLite 解码异常。

新增隔离回归保留真实生产 `App` / `WindowGroup` 和默认原生尺寸约束，仅将模型初始化、bootstrap、偏好设置和数据目录替换为夹具。修复前能够复现同类 `NSGenericException`。单纯隐藏 inspector 仍崩溃；空库时不挂载 inspector 才能停止循环。另发现只在 NSView 生命周期设置 contentMinSize 会让空库最小高度异常增至 1059；将最小尺寸移到 SwiftUI 根视图后，960×640 正常。

## 修改

- `Sources/SwitchShelfApp/RootView.swift`：游戏库为空时不安装原生 inspector；有游戏时保留原来的详情侧栏。根视图显式声明最小尺寸 960×640。
- `Sources/SwitchShelfApp/Theme.swift`：移除 NSView 挂载期间对 window.contentMinSize 的写入，避免与 SwiftUI 的尺寸约束竞争。
- `Sources/SwitchShelfApp/LibraryView.swift`、`SwitchShelfApp.swift`：空库时禁用详情侧栏按钮及快捷键菜单。
- `scripts/verify-ui-layout.sh`、`scripts/verify-empty-library-window.swift`：新增有界的真实 WindowGroup 回归模式。与离屏截图测试不同，它不会关闭 NSHostingView 的自动尺寸约束。

## 验证

- `scripts/verify-ui-layout.sh --empty-library-window`：通过。
- `scripts/verify-ui-layout.sh --empty-library-window --dark`：通过。
- 原有 `scripts/verify-ui-layout.sh`：24 个离屏布局全部生成，模式兼容性通过；不以该离屏结果代替上述真实窗口回归。
- 两个窗口测试均覆盖空库启动、1276×1410 / 960×640 / 1280×820 缩放、加入合成来源和游戏、移除最后来源、跳到设备页并回到空游戏库。夹具不启动 bootstrap，不扫描 NAS、不打开 USB、不安装文件，20 秒看门狗限制进程寿命。
- `swift test --skip RealNASScanTests`：274 项 Swift Testing、11 项 XCTest 全部通过。
- release 应用/探针构建及 `codesign --verify --deep --strict build/SwitchShelf.app` 通过。
- 重新打开本工作树的真实测试包后，进程存活且通过可访问性树和截图观察到“0 款游戏 · 0 个来源”“还没有游戏来源”，详情按钮禁用，未出现新的 SwitchShelf 崩溃报告。

未清空用户数据、未改 NAS 游戏文件、未执行安装、未替换桌面工作树的正式应用。真实应用启动自动进行了原有的只读设备探测，界面报告清单读取失败；这不是空库崩溃，设备清单仍未知，连接可靠性与首次 libusb GUI 授权仍是独立验收项。本修复不改变默认连接路线。
