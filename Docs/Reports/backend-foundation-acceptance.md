# USB Backend 软件基础验收 — 2026-10-23

本轮完成协议、原生 USB 适配器、允许列表范围读取、持久化传输记录和队列本地预检，已整合到 `codex/source-access-recovery`；尚未启用生产传输或安装。用户要求改用 pi 后，三个 Codex worker 均明确停止并保留工作区，此后的开发和交叉审查由三条 pi 终端并行完成。协调者负责范围、审查、cherry-pick、统一测试、打包及现场验收；未合并 main 或推送远端。

## 实现和证据

| 范围 | 结果 | worker 提交 / 整合提交 | 最终新增测试 |
|---|---|---|---|
| Protocol | DBI0 帧、分片输入、文件列表、允许列表范围请求、ACK、EXIT、有限预算、只关闭一次、唯一字节覆盖及可落盘进度回调 | `4ba62c8`、`87174d1` / `ffd178f`、`6451913` | 10 |
| USB | 显式打开的 IOKit C/Swift 适配器、描述符检查、有限读写、并发与取消、释放不确定时保留占用锁；要求调用方提供共享租约 | `413fa3a`、`54ee3a2`、`9d2463b` / `e9f2794`、`3f88413`、`9ccdea3` | 9 |
| Preflight/App | 当前快照的唯一内容 ID → URL 映射、仅元数据检查、协议文件名及清单大小约束、计划变化使结果过期；安装按钮禁用 | `21cb3fa`、`08e67bf` / `58874a2`、`b04a7ef` | 8 |
| FileAccess | 明确绑定的 ID/URL/大小、逐层 no-follow、最多 1 MiB 范围读取、前后元数据核对、FIFO/NUL/取消防护 | `1470dbd`、`5996d3a` / `62677a0`、`5beb822` | 5 |
| Journal | 有界解码、逐项覆盖与总量校验、原子替换及 fsync、重启将 active 改为 interrupted、落盘不确定时禁止继续更新；finished 要求记录 EXIT | 同上 | 10 |
| Integration | 小型临时源文件、真实预检与 reader、模拟分片设备、协议进度回调、日志重启；验证部分传输后失败，以及完整覆盖后显式 EXIT | `505123b` / `4f9ffe9` | 2 |

新增 Backend 测试共 **44 项**。主工作区运行 `swift test --skip RealNASScanTests` 通过 **127 项**（库 29、领域 8、设备 48、Backend 42），整合最后两个测试后运行 `swift test --filter BackendIntegration` 通过 **2 项**；合计验证 **129 项、0 失败**。这些是两条命令的结果，不是声称一次执行了全部 129 项。真实 NAS 扫描被统一验收命令跳过。

`python3 scripts/build-app.py` 发布构建、打包和本地 ad-hoc 签名通过；另行 `codesign --verify --deep --strict build/SwitchShelf.app` 通过。原生 C 桥使用当前 macOS SDK 的 `clang -fsyntax-only -Wall -Wextra -Werror` 通过。新产物是 `build/SwitchShelf.app`，没有发行公证或新外部运行时依赖。

协议依据为完整核对的官方 [`dbibackend`，固定提交 `22090afc64cc7b5d645a99bf3d4d8625a67b766e`](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/dbibackend)。它只提供主机文件交换步骤；实际 DBI 647 ACK 字段、原生接口打开与管道行为均无本轮实机证据。完整主机文件覆盖仅为 `transferredAwaitingConfirmation`，EXIT 也不证明设备安装成功。SD/NAND 是本地计划意向，主机协议不设置目标。

## 现场 UI 验收

22:49–22:55（北京时间）启动新版实际 `.app`。`cua_repl` 两次报告 `Sky Computer Use native pipe startup failed`；Orca CLI 在 App 启动、窗口出现并恢复后能够读取 AX 和 ScreenCaptureKit 截图，无需用户再次切换权限。

- 真实窗口显示 16 款游戏、1 个来源；选中 1-2-Switch 后，详情完整显示 2 个文件及“待确认”，此前的检查器白区本次没有复现，未据此推断旧问题原因。
- 原队列为空。临时加入该游戏的本地计划，实际“检查计划”显示 **2 个文件通过**；只读取 NAS 文件元数据，没有读取包体、连接 Backend 或安装。
- 取消选择其中一个内容后，现场显示“检查结果已过期”；重新检查显示 **1 个文件通过**。本地计划 JSON 核对为 1 项、1 个 included 文件，证明该选择已落盘。
- “开始安装”在这些状态中始终 disabled，界面明确说明本地检查不表示设备就绪或安装成功。
- 随后移除临时计划，现场和本地 JSON 均核对为 **0 项**，已回到全部游戏页面。没有留下测试安装计划。

CLI 动作回执中的通用 `unverified/accessibility_action_unasserted` 不被当作效果证据；上述结果来自后续 AX 状态、实际截图及本地 JSON。当前验收为亮色、1397×1282 窗口；深色、960×640 和真实离线断连场景仍未现场验收。日志和截图保存在忽略目录 `output/diagnostics/backend-foundation/`，不公开上传。

此前 Preflight worker 的一次完整测试额外执行了已存在的只读 NAS 元数据扫描（16 款、48 个包，0.341 秒），其“全部临时夹具”表述已在 `backend-preflight.md` 更正。后续范围测试和主工作区统一测试没有重复该扫描。

## 编排与额度事实

Orca Run `run_b35d87130bcd` 的九项任务均为 completed：协议核心、USB 适配器、队列预检、协议关闭/进度复审、存储/预检复审、USB 生命周期复审、跨模块联动、USB 故障隔离测试、reader/journal 修订。每个有效完成回执均已核对并处理，所有 Delivery 已确认；`worker-list --terminal-state reclaimable` 返回空。每个 settled worker 都执行了 release；复用的三条 pi 终端按 `external_terminal` 规则保留为空闲，三个原 Codex worker 已停止并释放，工作树保留。

首次 pi 结构化会话创建被 Orca 以 `agent_session_operation_invalid` 拒绝，没有遗留进程；随后采用文档支持的现有终端监督方式运行 pi。没有修改全局设置。**本机 pi 的默认提供方仍是 `openai-codex`，模型 `gpt-6-sol`**；已向用户说明并按其指定的 pi 当前配置继续，不能声称已换成另一额度来源。

## 下一步

1. 软件侧先实现具体的 MTP/Backend 共享跨进程租约，并让所有实际会话入口共同遵守；当前只有必须注入的租约接口，不能启用原生打开入口。
2. 将 Backend 原生操作和 SMB 范围读取纳入独立 helper 的退出确认与硬截止管理。actor 隔离不会强制中止阻塞的 `openat/pread` 或 IOKit 打开/关闭；当前仅协议协作预算和原生读写超时有界。默认 120 秒会话预算也不是已验证的大包生产配置。
3. 上述软件条件完成后，单独制定可审查的小测试包、目标、取消/断连及结果核对方案，再安排用户授权的 Backend 实机测试。当前不需要重复 MTP 重启或拔插；已安装清单仍是独立未解决能力。
4. 继续亮/暗、窄窗口及真实离线验收，之后再推进合法封面/元数据、发行等路线。

文件范围、API、限制和子模块证据分别见 `backend-protocol.md`、`backend-usb.md`、`backend-preflight.md`、`backend-storage.md`、`backend-integration-review.md`。源码游戏文件、设备内容及存档未被修改，没有执行真实 Backend 文件发送或安装。
