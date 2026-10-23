# SwitchShelf 项目交接文档

**截至 2026-10-23；状态：第一阶段代码已整合，现场验收未完成。** 本文供下一位协调者或开发者接手使用。不要把构建成功、USB 候选设备或离屏截图当成实机清单／实时 UI 验收。

## 1. 目标与不可越过的边界

项目是 macOS 26+、Swift 6 的原生 SwiftUI 游戏库应用，以 `output/design-demos/03-liquid-glass.png` 为选定视觉参考。第一阶段目标是只读本地／SMB 游戏库扫描及缓存、设备发现及只读已安装清单、保守的安装状态判断、可编辑的本地安装计划。架构与阶段计划分别见 `Docs/ARCHITECTURE.md`、`Docs/DEVELOPMENT_PLAN.md`。

`/Volumes/switch 游戏包` 的原始游戏文件和 Switch 设备只能只读访问；不得移动、修改、删除、上传或完整哈希大文件，不得写设备对象／存档。**安装、传输、删除仍未获授权，也不作为当前阶段的可执行功能。** 文件名中的 Title ID 和游戏身份是候选，不是包内容验证结果；缺失的设备覆盖、身份、安装状态保持未知。

## 2. 仓库、协调与交付物

- 主仓库：`/Users/jiazi/Desktop/SwitchShelf`，当前 `main` 为 `d6cdd9f`；本地交付物 `build/SwitchShelf.app`（临时 ad-hoc 签名，未公证／发行）。主仓库仅有未跟踪 `.pi/`，不属于交付代码。
- Orca Run：`run_6bf908529b8b`，接替协调者 generation 2；原 Codex 协调会话已结束。已有 agy 游戏库、pi 设备和 opencode UI worker 均以 `worker_done` 成功结束，报告和提交已核对。不要重复派工、覆盖其工作树或并发接管同一 Run。
- 原工作树：`/Users/jiazi/orca/workspaces/SwitchShelf/switchshelf-library`（`2632632`）、`switchshelf-device`（`3934869`）、`switchshelf-ui`（`792db23`、`5b5b587`）。UI 工作树还有未提交的 `Package.swift` 工具版本改动；未整合，勿覆盖。主仓库 cherry-pick 对应提交包括库 `14db18a`、设备 `f5d1132`、UI `dd94bb8` 与其报告 `833a197`。
- 协调者后续安全修订：`1347e72`（有界独立只读 probe）、`3dc5044`（旧 JSON 缓存安全迁移、候选内容安装状态保持未知、USB 重新枚举使旧清单失效）；验收报告 `53df640`、`d6cdd9f`。详细历史见 `Docs/Reports/coordinator-integration.md`。
- 原持久化 Goal `mvjqo0ez-e5cwsc` **已暂停**：审计、协调、整合、交付报告四项已完成；DBI 647 实机已安装清单验证等待用户确认。恢复该目标须由用户执行 `/goal-resume`；撰写本文不意味着已恢复设备操作。

## 3. 已实现与已验证

| 模块 | 当前实现与证据 |
|---|---|
| 游戏库 | `Sources/SwitchShelfLibrary/` 的只读 actor 扫描、文件名候选解析／归组、SQLite 缓存、部分扫描保留旧记录、多来源合并及离线保留。`swift test` 中真实 NAS 元数据扫描得到 **16 款归组游戏、48 个包、0 个扫描问题**，文件大小元数据合计 92,313,880,284 字节；未读完整包体。 |
| 领域判断 | `Sources/SwitchShelfDomain/InstallationAssessor.swift` 只在身份经验证且清单属于当前会话时判断；候选文件名、仅更新／DLC、覆盖不完整等不构成已安装证明。UI 单项内容同样不会因候选 Title ID 命中而报“已安装”。 |
| 设备 | `Sources/SwitchShelfDevice/`、`Sources/SwitchShelfProbe/` 支持 USB 枚举与只读 MTP inventory；`BoundedInventoryReader` 从 app 启动独立 helper，限时、序列化、验证 JSON／退出状态，退出无法确认时禁止重试。此前只读 USB 发现 **一个 `057e:201d` MTP 候选**；这不是已安装清单。 |
| UI／计划 | `Sources/SwitchShelfApp/` 已接入真实库和设备服务；侧边栏、网格／列表、搜索筛选、详情、设备、维护和本地编辑计划。计划执行按钮禁用，没有模拟传输进度／成功。UI worker 检查过亮／暗、宽／窄离屏布局，但非现场视觉验收。 |
| 构建测试 | 整合后 `swift test` **84 项通过**（库 30、领域 8、设备 46）；`swift build`、`python3 scripts/build-app.py`、`codesign --verify --deep --strict build/SwitchShelf.app` 通过。打包包含 `Contents/MacOS/switchshelf-probe`。仅本机 ad-hoc 签名。 |

旧 UI 原型曾将 215 字节 JSON 写成 `~/Library/Application Support/SwitchShelf/library.sqlite`。集成后的迁移识别该格式，将原件保留为 `.legacy-json-<UUID>` 备份并导入 SQLite；未知或损坏文件不自动覆盖。两项回归测试已覆盖此行为。

## 4. 未完成验收／真实限制

1. **实时 UI 与 NAS：** 终端测试能在约 0.22 秒完成只读扫描，但一次实际 `.app` 启动后的扫描在 Foundation `NSURLDirectoryEnumerator`／`open` 阻塞超过两分钟。进程随后由协调者终止；当时 app 的 SQLite 缓存中仍为 **0 款游戏**。可能与图形会话权限或挂载上下文有关，原因没有证明，不能声称 16 款已在实时 UI 显示。`orca computer get-app-state` 报 `permission_denied`，虽然权限查询显示 Accessibility 与 Screenshots 已获授权；会话当时锁屏。需用户解锁并审查可能出现的本地权限提示，再复现、定位、验收。不得伪称玻璃材质、按钮或交互已经现场确认。
2. **DBI 647-zhcn 已安装清单：** 用户报告 DBI 647-zhcn、固件显示 `19.0.1e`，并曾手动将 `[MTP Storages] 4: Installed games=true`；此前读取的是 DBI 重启前的九个 storage。已观察的 `1: SD内存卡` **不是** Installed games。没有重启后 Installed games 的 storage 名、层级、对象文件名、完整性或真实 installed records。`Docs/Reports/hardware-connection-647.md`、`device-647-compatibility.md` 详述以前的只读握手和局限。测试 fixture 的英文存储名、Title ID／版本／类型语法并非已证实的 647 中文版输出。
3. **产品后续：** 元数据／合法封面来源、安装 Backend 协议、授权测试包与目标、结果确认／重试／恢复、SD 维护及发行公证均属于后续阶段；不要将 disabled 队列误当可安装产品。

## 5. 接手后的顺序

1. **先请用户确认两件事：** (a) Mac 已解锁，能查看 SwitchShelf／Orca Computer Use 的权限提示；(b) Switch 上 DBI 已在启用 `4: Installed games=true` 后完全退出并重新打开，目前停留在 **「运行 MTP 传输程序」**，其他 MTP／USB 客户端均已关闭。未得到 (b) 的明确确认，不执行 inventory。
2. GUI 可用后，以 `build/SwitchShelf.app` 重试实时打开、NAS 只读扫描、游戏数、搜索／列表／队列／离线缓存、亮暗及 960×640 最小布局。若再次卡住，记录权限状态和阻塞位置，先修复 app 路径；不得用 CLI 16 款结果冒充 UI 呈现。
3. 确认唯一设备访问者且用户完成 DBI 操作后，由协调者 **仅运行一次独占、限时、只读** inventory probe；记录实际 storage 名、对象层级／命名、状态码、完整性、可解析身份。超时或 partial 时保持未知，不并发重试、不杀系统客户端、更不写设备。根据实测证据再决定是否需要 DBI 647 兼容改动。
4. 对新证据回归 `swift test`、`swift build`、app 打包与签名验证；更新本文和验收报告，报告明确已完成／未完成项及提交。大改共享领域模型或 `Package.swift` 前先协调。安装执行仍等待**另外**的用户审查批准。

## 6. 快速入口

- 构建／测试：`swift test`；`swift build`；`python3 scripts/build-app.py`；`codesign --verify --deep --strict build/SwitchShelf.app`。避免与其他 SwiftPM 命令并行写同一 `.build`。
- 只读历史证据：`Docs/Reports/acceptance-checkpoint.md`、`coordinator-integration.md`、`ui-opencode.md`、`hardware-connection-647.md`、`device-647-compatibility.md`。
- 本地 app 状态：`~/Library/Application Support/SwitchShelf/`（SQLite、计划 JSON 和旧原型备份）；不要随意删除用户数据。`build/` 为可重建产物；`/Volumes/switch 游戏包` 为只读源。
