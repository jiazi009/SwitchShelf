# SwitchShelf 项目交接文档

**截至 2026-10-23；状态：第一阶段代码已整合，现场验收未完成。** 本文供下一位协调者或开发者接手使用。不要把构建成功、USB 候选设备或离屏截图当成实机清单／实时 UI 验收。

## 1. 目标与不可越过的边界

项目是 macOS 26+、Swift 6 的原生 SwiftUI 游戏库应用，以 `output/design-demos/03-liquid-glass.png` 为选定视觉参考。第一阶段目标是只读本地／SMB 游戏库扫描及缓存、设备发现及只读已安装清单、保守的安装状态判断、可编辑的本地安装计划。架构与阶段计划分别见 `Docs/ARCHITECTURE.md`、`Docs/DEVELOPMENT_PLAN.md`。

`/Volumes/switch 游戏包` 的原始游戏文件和 Switch 设备只能只读访问；不得移动、修改、删除、上传或完整哈希大文件，不得写设备对象／存档。**安装、传输、删除仍未获授权，也不作为当前阶段的可执行功能。** 文件名中的 Title ID 和游戏身份是候选，不是包内容验证结果；缺失的设备覆盖、身份、安装状态保持未知。

## 2. 仓库、协调与交付物

- 主仓库：`/Users/jiazi/Desktop/SwitchShelf`，交接基线 `main` 为 `5ea444b`；本轮接手修订在 `codex/source-access-recovery` 分支，代码提交 `0b154a5`（来源访问）及 `c9fe0c4`（仅存储诊断），未合并主分支。本地交付物 `build/SwitchShelf.app` 已重新构建（临时 ad-hoc 签名，未公证／发行）。未跟踪 `.pi/` 不属于交付代码，未改动。
- Orca Run：`run_6bf908529b8b`，接替协调者 generation 2；原 Codex 协调会话已结束。已有 agy 游戏库、pi 设备和 opencode UI worker 均以 `worker_done` 成功结束，报告和提交已核对。不要重复派工、覆盖其工作树或并发接管同一 Run。
- 原工作树：`/Users/jiazi/orca/workspaces/SwitchShelf/switchshelf-library`（`2632632`）、`switchshelf-device`（`3934869`）、`switchshelf-ui`（`792db23`、`5b5b587`）。UI 工作树还有未提交的 `Package.swift` 工具版本改动；未整合，勿覆盖。主仓库 cherry-pick 对应提交包括库 `14db18a`、设备 `f5d1132`、UI `dd94bb8` 与其报告 `833a197`。
- 协调者后续安全修订：`1347e72`（有界独立只读 probe）、`3dc5044`（旧 JSON 缓存安全迁移、候选内容安装状态保持未知、USB 重新枚举使旧清单失效）；验收报告 `53df640`、`d6cdd9f`。详细历史见 `Docs/Reports/coordinator-integration.md`。
- 原持久化 Goal `mvjqo0ez-e5cwsc` **已暂停**：审计、协调、整合、交付报告四项已完成；DBI 647 实机已安装清单验证等待用户确认。恢复该目标须由用户执行 `/goal-resume`；撰写本文不意味着已恢复设备操作。

## 3. 已实现与已验证

| 模块 | 当前实现与证据 |
|---|---|
| 游戏库 | `Sources/SwitchShelfLibrary/` 的只读 actor 扫描、文件名候选解析／归组、SQLite 缓存、部分扫描保留旧记录、多来源合并及离线保留。`swift test` 中真实 NAS 元数据扫描得到 **16 款归组游戏、48 个包、0 个扫描问题**，文件大小元数据合计 92,313,880,284 字节；未读完整包体。 |
| 领域判断 | `Sources/SwitchShelfDomain/InstallationAssessor.swift` 只在身份经验证且清单属于当前会话时判断；候选文件名、仅更新／DLC、覆盖不完整等不构成已安装证明。UI 单项内容同样不会因候选 Title ID 命中而报“已安装”。 |
| 设备 | 支持 USB 枚举与只读 MTP inventory；`BoundedInventoryReader` 从 App 启动独立 helper，限时、序列化、验证 JSON／退出状态，退出无法确认时禁止重试。已真实完成一轮 inventory 及两次仅存储诊断（含用户拔插 USB 后），原生握手／枚举／关闭成功，均未发现 Installed games；不能报告已安装清单成功。新增显式 `storages` 模式不遍历内容对象。 |
| UI／计划 | `Sources/SwitchShelfApp/` 已接入真实库和设备服务；侧边栏、网格／列表、搜索筛选、详情、设备、维护和本地编辑计划。计划执行按钮禁用，没有模拟传输进度／成功。UI worker 检查过亮／暗、宽／窄离屏布局，但非现场视觉验收。 |
| 构建测试 | 最新 `swift test` **86 项通过**（库 30、领域 8、设备 48）；`swift build`、`python3 scripts/build-app.py`、`codesign --verify --deep --strict build/SwitchShelf.app` 通过。打包包含支持 `storages` 的 `Contents/MacOS/switchshelf-probe`。仅本机 ad-hoc 签名。 |

旧 UI 原型曾将 215 字节 JSON 写成 `~/Library/Application Support/SwitchShelf/library.sqlite`。集成后的迁移识别该格式，将原件保留为 `.legacy-json-<UUID>` 备份并导入 SQLite；未知或损坏文件不自动覆盖。两项回归测试已覆盖此行为。

## 4. 未完成验收／真实限制

1. **实时 UI 与 NAS：** 之前一次实际 `.app` 扫描阻塞超过两分钟，当时缓存为 0 款。本轮重新打包启动后，**2026-10-23 21:40:15（北京时间）的实际 App 缓存已有 16 款／48 个包／0 条扫描问题**；终端测试约 0.34 秒。此前卡住未复现，原因未知，不能归因于书签修复。用户随后提供权限已开启的现场截图；Orca CLI 仍报 `permission_denied`，但改用 `cua_repl` 原生控制后，**已确认真实窗口显示 16 款、来源在线，搜索“塞尔达”得 1 款，网格／列表切换及选择响应正常**。详情 AX 保持“待确认”。后续截图右侧出现白区，检查器视觉布局尚不能确认；队列编辑、离线场景、深色和 960×640 仍未完成现场验收。具体证据及范围见 `source-access-followup.md`。
2. **DBI 647-zhcn 已安装清单：** 用户已确认 `[MTP Storages] 4: Installed games=true`、完全退出重开 DBI、进入 MTP，并完成一次 USB 拔插重连。实际 catalog 仍为九项：标准 SD Card、SD／NAND install、Saves、中文 SD、金手指＆Mod、相册工具、主题、JKSV 存档备份，**没有 Installed games 入口**。用户确认 DBI 本机可以显示正常游戏列表，因此不能解释为无已安装游戏。配置实际加载位置、中文构建／版本问题未查明；尚未观察 Installed games 的对象语法、完整性或 installed records。最新证据及替代连接方案见 `Docs/Reports/mtp-storage-diagnosis.md`，不要重复要求用户完成已确认的重启／重连。
3. **产品后续：** 元数据／合法封面来源、安装 Backend 协议、授权测试包与目标、结果确认／重试／恢复、SD 维护及发行公证均属于后续阶段；不要将 disabled 队列误当可安装产品。

## 5. 接手后的顺序

1. **已有现场确认：** Mac 已解锁，`cua_repl` 可控制实际 App；用户已完成 DBI 配置确认、重启及 USB 重连。当前正在区分开启值是在 DBI 内部设置确认，还是仅检查过 SD 上的文件。用户已退出 MTP 查看本机游戏列表；下一次设备访问前确认已回到 MTP，避免重复此前无新条件的探测。
2. 继续以 `build/SwitchShelf.app` 完成检查器视觉问题、队列、离线场景、深色及 960×640；16 款窗口呈现、基础搜索及列表切换已有真实证据。Orca CLI 权限错误仍未定位，当前可用的 `cua_repl` 不需要用户再次开关权限。
3. 若继续清单排查，先核对 DBI 内部配置与实际启动 NRO／配置位置；仅在条件发生明确变化且设备重新就绪时运行一次独占、限时、只读 probe。可先用 `storages` 只看存储描述；Installed games 仍缺失就保持未知。不得猜测中文别名、遍历安装入口代替清单、并发重试或杀系统客户端。
4. 用户询问替代连接：后续安装建议采用 USB Backend，MTP 清单作为独立能力；FTP／HTTP 可作为网络补充，但其 647 清单接口尚未验证。未运行任何 Backend 传输或启用网络服务。安装执行仍需另外确定协议实现、测试包／目标及用户审查；不因连接方案讨论自动获得写设备授权。
5. 新代码已完成 86 项测试、构建、打包及签名验证。继续维护证据和报告；大改共享领域模型或 `Package.swift` 前先协调，不重新派发已完成 worker。详见 `source-access-followup.md`、`mtp-storage-diagnosis.md`。

## 6. 快速入口

- 构建／测试：`swift test`；`swift build`；`python3 scripts/build-app.py`；`codesign --verify --deep --strict build/SwitchShelf.app`。避免与其他 SwiftPM 命令并行写同一 `.build`。
- 仅存储诊断：在用户确认 MTP 就绪、无其他客户端后，使用 bundled `switchshelf-probe storages --transport native --timeout 30 --json`。exit 2 表示未读取安装清单，不是已安装内容为空。
- 只读历史证据：`Docs/Reports/acceptance-checkpoint.md`、`coordinator-integration.md`、`ui-opencode.md`、`hardware-connection-647.md`、`device-647-compatibility.md`。
- 本地 app 状态：`~/Library/Application Support/SwitchShelf/`（SQLite、计划 JSON 和旧原型备份）；不要随意删除用户数据。`build/` 为可重建产物；`/Volumes/switch 游戏包` 为只读源。
