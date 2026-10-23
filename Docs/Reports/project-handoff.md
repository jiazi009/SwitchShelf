# SwitchShelf 项目交接文档

**截至 2026-10-23；状态：USB Backend 软件基础已整合并完成 129 项测试及本地队列预检现场验证；生产传输／安装仍未启用。** 本文供下一位协调者或开发者接手使用。不要把构建成功、USB 候选设备或离屏截图当成实机清单／实时 UI 验收。

## 最新进展：pi 并行 Backend 基础

用户要求不再启动 Codex worker，已停止最初三个 Codex worker，随后三条 pi 终端完成协议、原生 USB、预检、reader/journal 和交叉验收；新 Run `run_b35d87130bcd` 的九项任务均 completed，所有回执已处理，没有 reclaimable 终端。pi 当前仍配置 `openai-codex/gpt-6-sol`，已说明该事实，未改变全局提供方或假定额度来源不同。

主工作区 Backend 代码截至 `4f9ffe9`，新产物 `build/SwitchShelf.app` 已重新打包并验证本地签名。127 项统一测试（跳过真实 NAS）加最后 2 项联动测试通过，合计 129 项。实际 App 预检 2 文件通过、修改选择后过期、重检 1 文件通过；开始安装始终禁用。临时计划已移除，现场和 JSON 均为 0 项。Orca CLI 原生观察目前可用；不必重复要求用户开关已确认的权限。

下一步软件工作是具体的 MTP/Backend 跨进程共享租约与独立 Backend/SMB helper 的硬截止／退出确认，再制定小包与目标的单独实机验证。当前不要重复原条件下的 MTP 拔插或进行 Backend 设备会话。完整证据、提交、限制见 `Docs/Reports/backend-foundation-acceptance.md`。

## 1. 目标与不可越过的边界

项目是 macOS 26+、Swift 6 的原生 SwiftUI 游戏库应用，以 `output/design-demos/03-liquid-glass.png` 为选定视觉参考。第一阶段目标是只读本地／SMB 游戏库扫描及缓存、设备发现及只读已安装清单、保守的安装状态判断、可编辑的本地安装计划。架构与阶段计划分别见 `Docs/ARCHITECTURE.md`、`Docs/DEVELOPMENT_PLAN.md`。

`/Volumes/switch 游戏包` 的原始游戏文件和 Switch 设备只能只读访问；不得移动、修改、删除、上传或完整哈希大文件，不得写设备对象／存档。**安装、传输、删除仍未获授权，也不作为当前阶段的可执行功能。** 文件名中的 Title ID 和游戏身份是候选，不是包内容验证结果；缺失的设备覆盖、身份、安装状态保持未知。

## 2. 仓库、协调与交付物

- 主仓库：`/Users/jiazi/Desktop/SwitchShelf`，交接基线 `main` 为 `5ea444b`；本轮接手修订在 `codex/source-access-recovery` 分支，代码提交 `0b154a5`（来源访问）及 `c9fe0c4`（仅存储诊断），未合并主分支。本地交付物 `build/SwitchShelf.app` 已重新构建（临时 ad-hoc 签名，未公证／发行）。未跟踪 `.pi/` 不属于交付代码，未改动。
- 历史 Orca Run：`run_6bf908529b8b`，接替协调者 generation 2；原 Codex 协调会话已结束。已有 agy 游戏库、pi 设备和 opencode UI worker 均以 `worker_done` 成功结束，报告和提交已核对。不要重复派工、覆盖其工作树或并发接管同一 Run。
- 原工作树：`/Users/jiazi/orca/workspaces/SwitchShelf/switchshelf-library`（`2632632`）、`switchshelf-device`（`3934869`）、`switchshelf-ui`（`792db23`、`5b5b587`）。UI 工作树还有未提交的 `Package.swift` 工具版本改动；未整合，勿覆盖。主仓库 cherry-pick 对应提交包括库 `14db18a`、设备 `f5d1132`、UI `dd94bb8` 与其报告 `833a197`。
- 协调者后续安全修订：`1347e72`（有界独立只读 probe）、`3dc5044`（旧 JSON 缓存安全迁移、候选内容安装状态保持未知、USB 重新枚举使旧清单失效）；验收报告 `53df640`、`d6cdd9f`。详细历史见 `Docs/Reports/coordinator-integration.md`。
- 原持久化 Goal `mvjqo0ez-e5cwsc` **已暂停**：审计、协调、整合、交付报告四项已完成；DBI 647 实机已安装清单验证等待用户确认。恢复该目标须由用户执行 `/goal-resume`；撰写本文不意味着已恢复设备操作。

## 3. 已实现与已验证

| 模块 | 当前实现与证据 |
|---|---|
| 游戏库 | `Sources/SwitchShelfLibrary/` 的只读 actor 扫描、文件名候选解析／归组、SQLite 缓存、部分扫描保留旧记录、多来源合并及离线保留。`swift test` 中真实 NAS 元数据扫描得到 **16 款归组游戏、48 个包、0 个扫描问题**，文件大小元数据合计 92,313,880,284 字节；未读完整包体。 |
| 领域判断 | `Sources/SwitchShelfDomain/InstallationAssessor.swift` 只在身份经验证且清单属于当前会话时判断；候选文件名、仅更新／DLC、覆盖不完整等不构成已安装证明。UI 单项内容同样不会因候选 Title ID 命中而报“已安装”。 |
| 设备 | 支持 USB 枚举与只读 MTP inventory；`BoundedInventoryReader` 从 App 启动独立 helper，限时、序列化、验证 JSON／退出状态，退出无法确认时禁止重试。已真实完成一轮 inventory 及两次仅存储诊断（含用户拔插 USB 后），原生握手／枚举／关闭成功，均未发现 Installed games；不能报告已安装清单成功。新增显式 `storages` 模式不遍历内容对象。 |
| UI／计划 | 原生库、搜索／详情、设备和持久化本地计划；现新增只检查元数据的 Backend 预检、过期检测及准确模式说明。现场已验证 2 文件通过 → 改变 included 选择后过期 → 1 文件通过，并清空临时计划；安装按钮始终禁用。 |
| Backend | `SwitchShelfBackend` 与 `CDBIBackendUSB` 实现真实主机协议、显式原生适配器、允许列表范围读取、原子传输记录和预检；主机覆盖／EXIT 不构成已安装证明。生产共享租约和强制截止 helper 尚未接通，App/CLI 无真实 Backend 打开路径。 |
| 构建测试 | 最新主工作区 129 项测试通过（统一 127 项加新增联动 2 项，跳过 RealNASScanTests）；发布构建、打包、严格 C 警告检查及 ad-hoc 签名验证通过。Backend 44 项全部使用临时文件／模拟设备，无实机 Backend 传输证据。 |

旧 UI 原型曾将 215 字节 JSON 写成 `~/Library/Application Support/SwitchShelf/library.sqlite`。集成后的迁移识别该格式，将原件保留为 `.legacy-json-<UUID>` 备份并导入 SQLite；未知或损坏文件不自动覆盖。两项回归测试已覆盖此行为。

## 4. 未完成验收／真实限制

1. **实时 UI 与 NAS：** 历史实际 App 扫描曾阻塞超过两分钟；随后缓存已恢复 16 款／48 包／0 问题，旧阻塞未复现、原因未知，不能归因于书签修复。基础搜索和网格／列表已有现场证据。本轮新版启动后 Orca CLI 读取 AX／截图恢复，实际窗口仍显示 16 款；1-2-Switch 检查器正常、安装状态待确认，旧白区没有复现。队列添加、included 编辑、元数据预检／过期／重检及 JSON 落盘已经现场验证，临时计划已清理。当前亮色 1397×1282；深色、960×640、真实离线断连仍待现场验收。详见 `source-access-followup.md` 与 `backend-foundation-acceptance.md`。
2. **DBI 647-zhcn 已安装清单：** 用户已确认 `[MTP Storages] 4: Installed games=true`、完全退出重开 DBI、进入 MTP，并完成一次 USB 拔插重连。实际 catalog 仍为九项：标准 SD Card、SD／NAND install、Saves、中文 SD、金手指＆Mod、相册工具、主题、JKSV 存档备份，**没有 Installed games 入口**。用户确认 DBI 本机可以显示正常游戏列表，因此不能解释为无已安装游戏。配置实际加载位置、中文构建／版本问题未查明；尚未观察 Installed games 的对象语法、完整性或 installed records。最新证据及替代连接方案见 `Docs/Reports/mtp-storage-diagnosis.md`，不要重复要求用户完成已确认的重启／重连。
3. **产品后续：** 元数据／合法封面来源、生产 Backend helper 与共享租约、授权测试包与目标、实机结果确认／重试／恢复、SD 维护及发行公证均属于后续阶段；不要将 disabled 队列误当可安装产品。

## 5. 接手后的顺序

1. 优先使用 pi，按新任务划分路径并复用已结算的终端；不重派已经完成的基础模块，不启动 Codex worker。提供方／额度如需切换，必须先确认具体配置，当前 pi 默认仍是 openai-codex。历史 Run 和暂停 Goal 不因本轮工作被重新接管／恢复。
2. 实现具体共享跨进程租约，覆盖现有 MTP helper／会话和未来 Backend；目前 USB 适配器只有必须注入的接口。未完成该组合前，不接通原生打开入口。
3. 实现独立 Backend/SMB helper 的硬截止、取消与退出确认，不能把 actor、协作预算或 IOKit 读写超时当成阻塞 syscall 的强制截止。核对真实 647 协议／接口行为前，不启用安装。
4. 软件条件成立后制定可审查的小测试包、目标、断连／取消与结果核对方案，再安排单独授权的设备测试。用户暂时不必反复进入 MTP、重启或拔插；已安装清单与安装传输仍是两个能力。
5. 若继续 MTP 清单排查，只在出现明确新条件且设备就绪时进行一次独占、限时、只读 probe；不要猜中文别名、遍历安装入口或杀系统客户端。已确认的配置／重启／重连不重复询问。
6. 继续亮／暗、窄窗口、真实离线及多项队列排序／目标的现场检查。基础窗口、所选检查器和本地预检已经验证；当前本地计划为 0 项。维护 `backend-foundation-acceptance.md` 与各子模块报告中的证据限制。

## 6. 快速入口

- 构建／测试：`swift test`；`swift build`；`python3 scripts/build-app.py`；`codesign --verify --deep --strict build/SwitchShelf.app`。避免与其他 SwiftPM 命令并行写同一 `.build`。
- 仅存储诊断：在用户确认 MTP 就绪、无其他客户端后，使用 bundled `switchshelf-probe storages --transport native --timeout 30 --json`。exit 2 表示未读取安装清单，不是已安装内容为空。
- 只读历史证据：`Docs/Reports/acceptance-checkpoint.md`、`coordinator-integration.md`、`ui-opencode.md`、`hardware-connection-647.md`、`device-647-compatibility.md`。
- 本地 app 状态：`~/Library/Application Support/SwitchShelf/`（SQLite、计划 JSON 和旧原型备份）；不要随意删除用户数据。`build/` 为可重建产物；`/Volumes/switch 游戏包` 为只读源。
