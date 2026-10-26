# DBI Backend 安装前协议一致性核对

- 项目：SwitchShelf（分支 `main`）
- 核对日期：2026-10-23
- 执行者：backend-conformance（团队 worker）
- 固定参考：`rashevskyv/dbi` 提交 `22090afc64cc7b5d645a99bf3d4d8625a67b766e` 的 `dbibackend`
- 范围声明：本轮**只做只读代码/文档检查与网络资料核对**；未接触或切换设备，未打开任何 USB 设备，未运行真实 Backend 传输，未安装驱动，未修改源码、`Package.swift`、测试或其他文档。唯一写入文件即本文件。
- 用途：为“用 DBI Backend 安装 834 MB `Untitled Goose Game` 本体 NSP 到 SD”的实机测试做安装前最后核对。

## 0. 结论摘要

一句话结论：**SwitchShelf 的主机侧线格式（DBI0 帧、命令、LIST/FILE_RANGE/EXIT 流程、文件范围负载）与固定版本官方脚本逐项一致；但“DBI 647-zhcn 实机行为”仍无任何实测证据，且仓库实现有若干处比官方脚本更严格，其中 ACK 字段校验和 057e:3000 描述符校验是安装前必须处理/取证的两项 P0。**

### 0.1 已可依赖的结论（证据 A/C）

1. 16 字节头：`DBI0` + `UInt32` type + `UInt32` command + `UInt32` payload length，全部小端。
2. type：request=0、response=1、ACK=2；command：EXIT=0、FILE_RANGE=2、LIST=3；legacy `LIST_OLD=1` 只在脚本中声明、从未处理。
3. 设备（Switch）主动发起 LIST；主机是被动应答方，不得先发送任何内容。
4. LIST：主机回 response 头（长度=UTF-8 清单字节数）→ 非空清单先读 16 字节 ACK → 再发明文清单（每个 basename + `\n`）。
5. FILE_RANGE：主机先写 ACK 头（长度=请求头里的 payload 长度）→ 读请求负载 → 回 response 头（长度=range size）→ 读 16 字节 ACK → 连续发文件字节。
6. FILE_RANGE 请求负载：`UInt32 size @0`、`UInt64 offset @4`、`UInt32 nameLen @12`、UTF-8 name `@16…`。
7. 官方脚本按 1 MiB（`0x100000`）读文件并写 USB，最后一块可短；没有逐块 ACK，也没有写入节流。
8. 主机协议没有 SD/NAND 目标选择命令，也没有安装结果回报；**EXIT 只表示设备要求主机结束，不等于安装成功**。
9. 官方脚本自 `a52a584e`（2023-10-26，提交信息 “DBI 616”）之后未再改动；固定提交处的 blob 与该提交完全相同（本轮已校验哈希）。

### 0.2 安装前必须处理或确认的事（P0/P1）

| 级别 | 事项 | 为什么 |
|---|---|---|
| P0 | 实机首次安装前，先只读抓取 `057e:3000` 的真实 USB 描述符（class/alt/端点数/端点地址） | 仓库 `bridge.c` 强制要求 class `0xff`、alt 0、恰好 2 个 bulk 端点 `0x01`/`0x81`；官方脚本只按 VID/PID 查找。647-zhcn 的 Backend 描述符从未观测过，不符会在协议开始前就被拒绝 |
| P0 | 决定 ACK 校验策略：要么临时记录原始 ACK 字节，要么按官方行为“读完 16 字节、忽略字段” | 仓库要求 ACK 的 type/command 正确且 payload length ≤ 65,536；官方脚本完全忽略这些字段。若 647 的 FILE_RANGE ACK 长度字段 > 65,536 或 command 值不同，主机将中止，而官方脚本可正常工作 |
| P1 | 建议首次安装使用 `--chunk 1048576`（与官方 1 MiB 节奏一致）；候选源在 SMB 上时尤其重要 | 仓库每读一块都会重新打开源文件并做 3 次 `fstat`；256 KiB 分块会让 834 MB 文件产生约 3,183 次读取（约 4.4 万次 SMB 路径 openat/stat 调用），1 MiB 分块约 796 次 |
| P1 | 会话预算建议 1800–3600 s；如设备在 DBI 完成画面停留超过单次 I/O 超时，按“超时未知”处理，不自动重试 | 官方脚本对命令头/ACK/数据写使用无限超时，失败才重连；仓库使用有限超时（helper 默认单 I/O 15 s、会话 1800 s）并 fail-closed |
| P1 | 安装结果只能以 Switch 端 DBI/HOS 显示为准；主机 exit code 0 仅为“主机已完整发送 + 设备请求 EXIT” | 协议没有安装成功/失败字段；README 与仓库文档均明确 EXIT 无安装语义 |

### 0.3 证据等级定义

| 等级 | 含义 |
|---|---|
| **A** | 官方脚本证据：本轮取得的固定提交 `dbibackend` 原始脚本，已用 GitHub Contents API 的 blob SHA 交叉校验 |
| **B** | 官方文档证据：同一固定提交的官方 `README.md`（本轮取得并与 `/tmp/switchshelf-dbi-README.md` 做过哈希比对） |
| **C** | 仓库既有文档/实现/测试证据：仓库内代码、测试与 `Docs/Reports`、`Docs/Tasks` |
| **D** | 未验证假设：尤其指 DBI 647-zhcn 实机的设备端行为；本报告不作任何实机断言 |

---

## 1. 证据来源与取得过程

### 1.1 官方脚本（已取得；A）

| 尝试路径 | 结果 |
|---|---|
| `web_fetch https://raw.githubusercontent.com/.../dbibackend` | 失败：`URL hostname "raw.githubusercontent.com" resolves to a non-public IP address` |
| `web_fetch https://cdn.jsdelivr.net/gh/rashevskyv/dbi@<commit>/dbibackend` | 失败：同样报 non-public IP |
| `web_fetch https://raw.githack.com/rashevskyv/dbi/<commit>/dbibackend` | 失败：同样报 non-public IP |
| `web_fetch https://github.com/rashevskyv/dbi/blob/<commit>/dbibackend` | 失败：同样报 non-public IP |
| `curl` 直连 `raw.githubusercontent.com` 固定提交 URL | **成功**：HTTP 200，7,715 字节，263 行 |
| GitHub Contents API（`?ref=22090afc…`）读取 `dbibackend` | 成功：`sha = 85e7285e92313b5ee262e52ec5b41e31fc88f622`，`size = 7715` |

校验（本地检查副本 `/tmp/dbibackend.curl.txt`，**未提交、不随报告分发**）：

```
git hash-object /tmp/dbibackend.curl.txt
  → 85e7285e92313b5ee262e52ec5b41e31fc88f622   # 与 GitHub blob SHA 相同
shasum -a 256 /tmp/dbibackend.curl.txt
  → 0202d4ab2cfdd281762180d3deb1862558ccafa477ba0ccd104cc3a9ae9b7c64
```

固定提交本身（GitHub API）：

- `sha = 22090afc64cc7b5d645a99bf3d4d8625a67b766e`
- 提交时间 `2026-10-09T09:39:28Z`，提交信息首行 `Merge pull request #407 from arebaka/main`
- `commits?path=dbibackend` 显示该路径最后一次改动是 `a52a584e99e6`（2023-10-26，提交信息 “DBI 616”）；在 `a52a584e` 处读取同一文件，blob SHA 仍为 `85e7285e92313b5ee262e52ec5b41e31fc88f622`、大小仍为 7,715 字节。**即：该主机脚本自 2023-10-26 起未再变化。**

> 说明：脚本许可证尚未确定；本轮未运行该脚本（未装 PyUSB、未连接设备），也未在本仓库复制整份脚本；本报告只做独立行为转述（见附录 B）。`dbibackend` 只证明“主机侧脚本行为”，不证明任何 DBI 设备端实现。

### 1.2 官方 README（B）

- 固定提交的 `README.md`：63,440 字节，`git hash-object = 89cc69da63fd9f8aa0976b6130264bce9a56352e`，SHA-256 `da6459cb310525dbab294978f709deb4903951ffe45d3e41ce8548d9ae76fc48`。
- 将该文件与工作区既有的 `/tmp/switchshelf-dbi-README.md` 比对：`diff` 完全一致、哈希一致 → **既有 `/tmp` 文件就是固定提交 README 的完整副本**，可作为官方文档证据使用（等级由“来源不明二手资料”升为 B）。
- 注意：固定提交的 README 自身在第 71–96 行附近留有未合入的冲突标记（上游仓库状态），因此本报告只引用无冲突的 “Install title from DBIbackend” 小节（约 L150–170）与 USB/udev 相关段落。
- README 关键事实（B）：
  - 入口：主菜单 **Install title from DBIbackend**，热键 **(Y)**（L154、L101）。
  - 流程：先启动 dbibackend 并 Start server，再用 USB-C 连 Switch，然后在 DBI 选择该入口（L156）。
  - Windows 需 libusbK 驱动；macOS/Linux 只需 PyUSB（L158、L180–190）。
  - udev 规则使用 `idVendor=057e, idProduct=3000`（L189）。
  - 目标与安装动作在 DBI 设备端选择/显示（“select and install your files … in the same fashion as using Browse SD Card/Browse USB0 Drive”，L160）。
  - USB 3.0 需要 kefir 或 Atmosphere `usb30_force_enabled` 配置；否则为 USB 2.0（L882–890）。
  - 示例 `dbi.config` 的 `[MainMenu]` 中 `BackendInstall=true`（L748–749），即该菜单项默认启用；用户本机配置是否仍为 true 未核实（D）。
  - 设备端错误提示包括 `Transfer error`、`TRANSFER CRC ERROR`、`TRANSFER ABORTED` 等（README “Warnings and Errors”，B）。这些是实机失败时需要在 DBI 屏幕上记录的现象。

### 1.3 仓库证据（C）

本轮实际阅读（只读）：

| 文件 | 用途 |
|---|---|
| `Sources/SwitchShelfBackend/Protocol/BackendCodec.swift` | 帧、命令、名称、range 负载解析 |
| `Sources/SwitchShelfBackend/Protocol/BackendSession.swift` | 会话循环、ACK、分块、进度、关闭语义 |
| `Sources/SwitchShelfBackend/BackendContracts.swift` | transport/reader/结果/错误契约 |
| `Sources/SwitchShelfBackend/USB/BackendUSBTransport.swift` | 显式 open、lease、进程栅栏、1 MiB/60 s 上限 |
| `Sources/CDBIBackendUSB/bridge.c` + 头文件 | 057e:3000 描述符校验、接口打开、ReadPipe/WritePipe |
| `Sources/SwitchShelfBackend/Preflight/BackendPreflight.swift` | 名称/大小/清单上限预检 |
| `Sources/SwitchShelfBackend/FileAccess/AllowlistedBackendFileReader.swift` | 允许列表范围读取（每块重开+元数据核对） |
| `Sources/SwitchShelfBackend/Journal/BackendTransferJournal.swift` | 主机侧持久进度 |
| `Tests/SwitchShelfBackendTests/ProtocolSessionTests.swift`、`IntegrationBackendTests.swift`、`BackendUSBTests.swift` | fake-peer 协议/集成/描述符测试（阅读其覆盖范围，本轮未执行） |
| `Docs/Reports/backend-protocol.md`、`backend-integration-review.md`、`backend-foundation-acceptance.md`、`backend-preflight.md`、`backend-usb.md` | 既有协议/实现结论 |
| `Docs/Reports/hardware-connection-647.md`、`Docs/Reports/device-647-compatibility.md` | DBI 647-zhcn 实机连接/版本的用户报告 |
| `Sources/SwitchShelfBackendInstall/*`、`Sources/SwitchShelfBackendCLI/main.swift`、`Docs/Reports/backend-install-helper.md` | 当前 helper 默认值与 CLI 行为（**读取时为未提交工作区状态，最终以 Lead 提交版本为准**） |
| `Docs/Tasks/backend-install-field-test.md` | task-2 的现场计划与只读预检：候选包精确路径/大小/SMB 挂载/当前设备状态（C 级二手证据，本轮未复跑其命令） |

> 本轮**未运行** `swift build`/`swift test`（任务要求只读核对，且 Lead 正在同一工作区实现 helper）；上表测试代码只作为“已覆盖哪些语义”的阅读证据，运行结果以 Lead 的报告为准。

仓库既有结论与本轮独立核对一致：`Docs/Reports/backend-protocol.md` 与 `backend-integration-review.md` 已记录相同的线格式、ACK 顺序与“EXIT 不等于安装成功”；本报告补充了本轮脚本哈希/历史证据、与官方脚本的严格化差异清单，以及面向实机安装的检查与失败处理。

### 1.4 未验证假设（D）

- DBI 647-zhcn 的设备端实现是否与上游固定脚本时代的行为完全一致（中文版是否只改界面/语言，还是改动过 Backend 协议或时序）。
- 647-zhcn 上 `057e:3000` 的实际描述符（interface class、alt、端点数与端点地址）。
- DBI 647-zhcn 实际发送的 ACK 字段（type/command/payload length）、FILE_RANGE 请求的 range 大小、EXIT 的 payload 与触发时机。
- `dbi.config` 中 `BackendInstall` 是否仍为 `true`（README 示例默认 `true`，但本机配置此前被用户改过 MTP 段，且既有报告只打印了部分配置段）。

> 本轮**没有**做任何设备枚举（未运行 `ioreg`/`system_profiler`/`discover`），也没有接触用户当前设备状态；上表 D 项只能由实机检查消除。

---

## 2. 官方主机脚本核对摘要（A）

### 2.1 常量与帧

| 项目 | 官方脚本（A） | 依据 |
|---|---|---|
| 头长度 | 16 字节 | `struct.pack('<4sIII', …)` |
| 头布局 | magic `DBI0`（4B）· type UInt32 LE · command UInt32 LE · data_size UInt32 LE | 同上 |
| type | `REQUEST=0`、`RESPONSE=1`、`ACK=2` | L26–28 |
| command | `EXIT=0`、`LIST_OLD=1`、`FILE_RANGE=2`、`LIST=3` | L21–24 |
| 分块 | `BUFFER_SEGMENT_DATA_SIZE = 0x100000`（1 MiB，主机读文件/写 USB 的最大段） | L30 |
| 端点 | 写 `0x01`、读 `0x81`（bulk） | L44/46/56/58/79/86/110/127/130/139 |
| 设备匹配 | `usb.core.find(idVendor=0x057E, idProduct=0x3000)`（取第一个匹配；不校验 interface class/alt/端点） | L145 |
| 主机来源 | 文件清单来自启动参数（文件或目录内的普通文件），键为 **basename**，值为解析后的绝对路径 | L251–262 |

### 2.2 会话流程（A）

1. 主线程启动 GUI 后由“Start server”创建 daemon 线程；线程先阻塞等待 057e:3000 出现（每秒重试），随后进入命令循环。
2. 命令循环每次读 16 字节；只有 magic 不是 `DBI0` 时跳过继续；**type 与未知 command 不校验、不报错**。
3. `EXIT(0)`：不校验 payload，写 `RESPONSE(EXIT, 0)` 后退出 GUI/进程。
4. `LIST(3)`：把内部 `file_list` 按插入顺序拼成 `basename + "\n"` 的 UTF-8 清单；写 `RESPONSE(LIST, 清单字节数)`；清单非空时读 16 字节 ACK（**不校验**）后再写清单字节；清单为空则无 ACK、无 payload。
5. `FILE_RANGE(2)`：
   - 先写 `ACK(FILE_RANGE, 请求头 data_size)`；
   - 再读 `data_size` 字节请求负载；
   - 解析：`size=UInt32[0:4]`、`offset=UInt64[4:12]`、`name_len=UInt32[12:16]`，**name = 第 16 字节之后的全部字节**（`name_len` 只打印不校验）；
   - 写 `RESPONSE(FILE_RANGE, size)`；
   - 读 16 字节 ACK（**不校验任何字段**）；
   - 打开 basename 对应文件、`seek(offset)`，循环发送 `size` 字节，每段最多 1 MiB，最后一段可短；无逐块 ACK、无 sleep/节流。
6. 出错处理：任何 `usb.core.USBError` 都会打印 “Switch connection lost”，然后进入“等待设备重新出现”的循环（**不重试当前命令、不通知设备**）。其它 Python 异常（未知文件名 KeyError、非法 UTF-8、读写失败）会直接让该 daemon 线程结束，主机不再应答。

### 2.3 官方脚本的 I/O 超时（A + PyUSB 公开源码）

| 调用 | 脚本写法 | 实际超时 |
|---|---|---|
| 命令头 / LIST ACK / FILE_RANGE 第二 ACK 读取 | `dev.read(0x81, 16, timeout=0)` | 无限等待 |
| 文件数据写入 | `dev.write(0x01, data=buf, timeout=0)` | 无限等待 |
| FILE_RANGE 请求负载读取 | `dev.read(0x81, data_size)` | 未指定 → PyUSB 默认超时（当前 PyUSB 源码 `_DEFAULT_TIMEOUT = 1000` ms） |
| 各握手/应答头写入 | `dev.write(0x01, …)` | 未指定 → 默认 1,000 ms |

> PyUSB 版本未在脚本中固定；以上默认值只影响等待时长，不影响线格式。另：PyUSB 在首次对某端点 I/O 时会自动 claim 该端点所在接口（`usb/core.py` 的 `_ResourceManager.setup_request` → `managed_claim_interface`），因此脚本本身没有显式 `claim_interface`/`set_configuration` 调用。

### 2.4 官方脚本明确**没有**的东西

- 没有 SD/NAND 目标选择命令或目标字段。
- 没有安装成功/失败/进度回报命令；EXIT 只是设备要求主机结束。
- 没有校验 ACK 的 type/command/length，也没有“ACK 长度必须等于前一个长度”的约定。
- 没有校验 `name_len == len(name)`。
- 没有逐块 ACK、重传、断点续传或重连后的命令重放。
- 没有固定 `data_size` 上限（主机端只受 Python/内存约束）；没有限制清单字节数。
- 没有显式 `set_configuration` / `claim_interface` / `set_interface_altsetting` 调用。

---

## 3. 逐项对照表

图例：**一致** = 线格式/语义一致；**更严格** = 仓库在官方行为之上额外拒绝/校验；**未验证** = 需要 DBI 647-zhcn 实机证据。

| # | 项目 | 官方脚本（A） | 仓库实现（C） | 判定 | 风险/说明 |
|---|---|---|---|---|---|
| 1 | 设备匹配 | 只按 VID `0x057E` + PID `0x3000` 取第一个设备 | `bridge.c`：恰好一个 057e:3000；interface class `0xff`、alt `0`、恰好 2 个端点、bulk OUT `0x01`、bulk IN `0x81`、单一匹配接口；`USBInterfaceOpen`（不 seize）、不改配置、不读序列号 | 端点/ID 一致；仓库**更严格** | 647-zhcn 的 Backend 描述符未观测（D）；若不符，`open` 前/中失败 |
| 2 | 16B 头 | `DBI0` + 3×UInt32 LE | 完全一致（`headerSize = 16`） | 一致 | — |
| 3 | type 值 | 0/1/2；入站不校验 type | 0/1/2；入站请求要求 type=0，否则 `protocolViolation` | 定义一致；仓库**更严格** | 低风险：DBI 预期发 0（未实测） |
| 4 | command 值 | EXIT=0、LIST_OLD=1、FILE_RANGE=2、LIST=3；未知 command 静默忽略 | 只接受 0/2/3；1 及其它 → `unsupportedCommand`/`protocolViolation`，中止 | 一致；仓库**更严格** | 若 DBI 使用 legacy LIST=1，官方也无人应答（会卡住），故不太可能 |
| 5 | payload length 语义 | LIST response=清单 UTF-8 字节数；FILE_RANGE response=range size；FILE_RANGE ACK=请求 data_size；EXIT=0 | 主机生成侧相同；设备来包：LIST/EXIT 请求必须 0、FILE_RANGE 请求 17…65,536、ACK length ≤65,536 | 主机侧一致；设备侧**更严格** | ACK length 上限为 P0 未知项 |
| 6 | 谁先发起 LIST | DBI 发起；主机只读命令、被动应答 | 会话第一步即读 16 字节命令头，从不主动写 | 一致 | — |
| 7 | LIST 请求 payload | 不检查 | 必须为 0 | 更严格 | 低风险（预期 0） |
| 8 | LIST 应答 + ACK | 写 response 头 → 非空则读 16B ACK（忽略字段）→ 写清单；空清单无 ACK | 相同；校验 ACK type=2、command=LIST、length ≤65,536 | 流程一致；ACK 校验**更严格** | 单文件清单约几十字节，LIST ACK 超限概率低 |
| 9 | 清单内容/编码 | 插入序 `basename + "\n"`，UTF-8，长度按字节 | offer 顺序 `name + 0x0a`，UTF-8，长度按字节；名称唯一、禁止 `/ \ :`、控制/换行字符；预检限 65,536 字节 | 一致（顺序无协议意义）；名称规则**更严格** | 候选名若为 ASCII 无影响；中文 UTF-8 两者均支持 |
| 10 | FILE_RANGE 先 ACK 后负载 | 先写 `ACK(FILE_RANGE, data_size)`，再读 `data_size` 字节 | 相同 | 一致 | — |
| 11 | FILE_RANGE 负载格式 | size UInt32@0、offset UInt64@4、nameLen UInt32@12、name UTF-8@16…；忽略 nameLen | 相同偏移/宽度；要求 nameLen == 剩余字节数，且 name 合法 UTF-8/安全文件名 | 布局一致；nameLen **更严格** | 官方按 name 精确查表，隐式要求 name 恰为 basename；低风险 |
| 12 | 名称匹配 | Python dict 精确字符串匹配；重复 basename 后者覆盖 | 按 UTF-8 字节精确匹配唯一 offer；重复名称预检拒绝 | 一致 + 更安全 | 单文件无影响 |
| 13 | range 边界 | 不校验；越界/负偏移由文件读取异常终止线程 | 校验 offset+size 溢出与 ≤ offer.byteCount，否则 `rangeOutOfBounds` | 更安全 | 正常 DBI 请求不会越界 |
| 14 | FILE_RANGE 应答 + 第二 ACK | 写 response 头（size=range size）→ 读 16B ACK（忽略） | 相同；ACK 校验 type/command/length | 流程一致；ACK 校验**更严格** | P0 未知项（同上） |
| 15 | 数据分块/节奏 | 1 MiB 读/写；最后一块可短；连续、无节流、无逐块 ACK；写超时无限 | helper 默认 256 KiB，可配 1 MiB；transport 上限 1 MiB；顺序写，无逐块 ACK；每块后 journal + progress | 协议等价；节奏不同 | 功能风险低（官方末块任意短说明设备可接受短包）；性能风险见 §5 |
| 16 | 结束/关闭 | 收到 EXIT 写 response 后进程退出；无显式 close/清理 | 收到 EXIT 后结束会话；transport 恰好 close 一次；release 失败 → `releaseUnverified` 并栅栏 | 结束语义一致；仓库多了安全清理 | — |
| 17 | 超时/重试 | 命令头/ACK/数据写无限；部分读写 1 s 默认；USB 错误 → 等待设备重连，不重试命令 | 有限超时（helper 15 s/次、1800 s/会话）、不重连、不重试写、fail-closed | 语义不同（方向一致：不假装成功） | 设备 finalize/慢 SD 时可能主机先超时（D） |
| 18 | 目标选择 | 没有目标命令；README 说在 DBI 端选择/安装 | `intendedTarget` 只是本地记录，不发给设备；`--target` 仅意图 | 一致 | 用户必须在 Switch 屏上选 SD（D：647-zhcn 菜单文案未知） |
| 19 | 安装结果 | 无结果字段；EXIT ≠ 成功 | 主机侧最多 `transferredAwaitingConfirmation`；journal `finished` ≠ 已安装 | 一致 | 只能在设备端验证 |
| 20 | 多文件/重复 LIST | 支持一个会话内重复 LIST/FILE_RANGE | 支持多 offer、重复 LIST/重叠范围；本场景单文件 | 一致 | — |

---

## 4. 明确一致、可直接依赖的部分（A/C）

1. **帧/常量**：头长、magic、type、command、端序与字段偏移一致；`BackendCodec` 没有“自创”字段。
2. **交互顺序**：设备先 LIST，主机被动应答；FILE_RANGE 的“ACK 头 → 请求负载 → response 头 → 第二 ACK → 文件数据”顺序与官方脚本相同；主机从不主动写。
3. **负载格式**：range 三个字段的宽度/偏移/小端序与官方解包完全一致；name 按 UTF-8 处理。
4. **清单格式**：`basename + LF`、长度按 UTF-8 字节、非空才等待 ACK——与官方一致。
5. **EXIT 语义**：仓库与官方都不把 EXIT 当安装结果；仓库还把它与主机完整性分离（`peerRequestedExit` 与每文件 phase）。
6. **职责边界**：仓库没有目标选择命令、没有伪造安装结果；`Docs/Reports/backend-protocol.md`、`backend-preflight.md` 与 README 的边界一致。
7. **安全增强（不改变线格式）**：名称/范围/长度校验、`close` 恰好一次、共享设备租约、失败不重连、journal 持久化均不改变主机发出的字节语义。

---

## 5. 严格化差异与可能的不一致（按风险排序）

### P0-1 ACK 字段校验可能过严（最可能在实机首跑时失败）

- 官方：读 16 字节后完全不校验 type/command/length；也从不读取 ACK payload。
- 仓库：`acknowledge()` 要求 `type == .acknowledgement`、`command` 与当前命令一致、`payloadSize <= maximumCommandPayload`（默认 65,536）。
- 触发条件（任一）：DBI 647 的 FILE_RANGE ACK 的 `data_size` 字段等于 range 大小（若 range > 64 KiB，例如 1 MiB，则会 > 65,536）；或 ACK 的 command/type 值与仓库枚举不同。
- 后果：主机在发送文件数据之前 `protocolViolation` 中止；DBI 端可能显示传输中断。
- 建议：
  - 首次实机安装前，Lead 可选择**按官方行为**处理 ACK：仍读 16 字节，但不以 length 字段作为中止条件（至少对 FILE_RANGE ACK 放宽长度上限）；type/command 校验是否保留由 Lead 决定。
  - 或者保留严格校验但增加**原始 ACK 字节记录**（前 16 字节 hex 写入 journal/日志），使首跑失败可直接区分“ACK 字段差异”与其它问题。
  - 两种方案都无需改协议字节，具体改法属于 Lead 的实现范围；本报告不修改代码。

### P0-2 057e:3000 描述符强制校验 vs 官方只按 VID/PID

- 官方：只要 VID/PID 匹配就取第一个设备；interface class/alt/端点数/端点地址均未检查（端点地址写死在 I/O 调用中）。
- 仓库：`ss_usb_is_backend()` 强制 class `0xff`、alt 0、恰好 2 端点、OUT `0x01`/IN `0x81` bulk、唯一匹配接口；`BackendUSBTransport` 还要求恰好一个设备。
- 现状：仓库/历史报告只观测过 MTP（`057e:201d`）与普通 Switch（`057e:2000`）描述符；**`057e:3000` 从未被观测**。
- 建议：安装前用只读 `ioreg`/`system_profiler` 抓取真实 Backend 模式的描述符并存档。若描述符不符，**不要**为了“先试一下”绕过校验——那可能打开错误接口。把描述符差异作为独立问题回报。

### P1-1 超时/重连语义不同

- 官方：命令头/ACK/数据写无限等待；USB 错误后重连；不重试命令。
- 仓库：有限超时（helper：15 s/次 I/O、1800 s/会话）、不重连、fail-closed。
- 风险：DBI 在 SD 写入/安装收尾/完成画面期间可能长时间不发下一命令或不读数据，主机可能先超时。若发生，设备端可能仍在安装，**结果是未知而不是失败**。
- 建议：保留 15 s 单次 I/O 首次值；若日志显示“读命令头超时”时 DBI 屏幕仍在正常安装/完成，Lead 可把会话预算 `--timeout` 提到 3600 s；单次 I/O 15 s 由 helper 内部 `operationTimeoutMilliseconds` 设置（无 CLI 开关），如需调高（transport 上限 60 s）要改代码。

### P1-2 分块大小与 SMB 源文件开销

- 官方 1 MiB/段；helper 默认 256 KiB（`--chunk` 可设到 1 MiB）。
- 仓库读取路径 `AllowlistedBackendFileReader.read()` 每块都会：逐层 `openat` 打开路径、`fstat`、`pread`、再 `fstat`、再重新打开路径并 `fstat`。候选源已由 task-2 只读预检确认在 SMB 挂载上（`smbfs`，`/Volumes/switch 游戏包`），834,297,609 字节：
  - 256 KiB → 约 3,183 块 → 约 4.4 万次 SMB 路径 `openat`/`stat` 调用、3,183 次 journal 原子写；
  - 1 MiB → 约 796 块 → 约 1.1 万次、796 次 journal 写。
- 风险：SMB 元数据/读延迟可能显著拖慢总时长，甚至让设备端等待超时（D：DBI 侧超时未知）。
- 建议：首次安装用 `--chunk 1048576`；若出现传输不稳再回退 262144。若 SMB 读延迟成为瓶颈，只在用户明确授权下考虑本地副本（会增加约 834 MB 临时空间与复制时间，不是协议要求）。

### P1-3 命令数预算与 DBI 的 range 大小

- helper 当前把 `maximumCommands` 设为 50,000（`BackendSession` 默认 4,096，选项上限 100,000）。
- DBI 每次 FILE_RANGE 请求的 size 未知（D）。834,297,609 字节若按 16 KiB 请求，需要约 50,922 次命令，**会超过 50,000**；若请求更大（≥32 KiB）则足够。
- 失败特征：进度接近 100%（如 98%）后报 timeout。若出现，建议 Lead 把 `maximumCommands` 提到 100,000（无需其它改动）。

### P2 其它严格化差异（低风险，但实机失败时可按表排查）

| 差异 | 官方行为 | 仓库行为 | 首跑可能后果 |
|---|---|---|---|
| 请求 type 校验 | 忽略 type | 必须 `request(0)` | 若 DBI 发非 0，立即 `protocolViolation` |
| EXIT payload | 不校验 | 必须为 0 | 若 EXIT 携带非零长度（例如结果码）会中止；但官方也无从利用该字段 |
| LIST 请求 payload | 不校验 | 必须为 0 | 低 |
| `nameLen` 一致性 | 忽略 nameLen，取 `[16:]` | 要求 `nameLen == len(name bytes)` | 低（官方按 name 精确查表也隐含要求如此） |
| 未知 magic | 跳过继续 | 中止 | 实机 DBI 应始终发 `DBI0` |
| legacy LIST=1 | 静默忽略（会卡住） | 明确失败 | 两边都无法完成；低 |
| 重复 basename | dict 后者覆盖 | 预检拒绝 | 本场景单文件无影响 |
| 非 UTF-8/非法名 | 线程崩溃 | 明确失败并关闭 | 更安全 |

---

## 6. 对 DBI 647-zhcn 的未知项（D）

| 未知项 | 为什么重要 | 安装前如何降低风险 |
|---|---|---|
| 647-zhcn 与上游固定脚本时代的行为是否一致（中文版是否只本地化 UI） | 若设备端协议有改动，所有主机侧一致性都可能失效 | 只能实机验证；首次运行保留完整主机日志 + 设备截图 |
| `057e:3000` 的真实描述符（class/alt/端点数/端点地址/是否唯一） | 不匹配会在 open 阶段被仓库拒绝（P0-2） | 进入 Backend 模式后只读 `ioreg`/`system_profiler`，保存输出 |
| LIST ACK 与 FILE_RANGE ACK 的实际 type/command/payload length | 仓库校验更严格（P0-1）；错配会在首跑中止 | 首跑记录原始 ACK（或按官方忽略字段）；把失败日志作为证据 |
| DBI 每次 FILE_RANGE 请求的 range 大小 | 影响命令数预算、进度粒度、journal 次数（P1-3） | 通过主机侧总命令数/range size 日志观察；必要时提高 `maximumCommands` |
| 设备是否接受非 1 MiB/非对齐的主机写块 | 仓库 256 KiB 默认与官方 1 MiB 不同（P1-2） | 首次用 1 MiB；失败时回退 256 KiB 并记录 |
| EXIT 的触发时机与 payload | 主机把 EXIT 当作结束信号；若设备在安装收尾/错误时也发 EXIT，主机只能报“待确认” | 记录 DBI 屏幕时序（安装完成/报错/退出）与主机 EXIT 时间的先后 |
| DBI 安装收尾耗时 | 超过单次 I/O 超时会让主机先断开，结果未知（P1-1） | 现场观察；必要时提高超时后重跑 |
| 断开/超时后设备端状态与可恢复性 | 决定重跑是否需要先清理/重启 DBI | 失败后先看 DBI 屏幕，再退出/重进 Backend 模式；不在同一进程自动重试 |
| 目标选择（SD/NAND）在 647-zhcn 的菜单文案、默认值与是否记忆 | 仓库不能设置目标；选错会装到错误介质 | 用户在设备端确认 Target=SD；拍照留证 |
| 安装结果/错误在 647-zhcn 屏幕上的实际显示（含中文） | 主机协议无结果回报 | 实机记录 DBI “Browse installed applications”/主界面结果 |
| `dbi.config` 的 `BackendInstall` 是否为 `true`（README 示例默认 true） | 若被关闭，主菜单没有该入口 | 在 DBI 设置/配置中确认；不要在本轮安装测试中顺便改配置 |
| DBI 启动模式（applet vs title override）对 Backend 安装的影响 | README 主推 applet 模式；MTP 已实测；Backend 未实测 | 默认按 README 启动；若失败，再按 README 建议尝试 title override |
| USB 3.0 是否启用（kefir / `usb30_force_enabled`） | 影响速度，不影响线格式 | 首次不刻意修改系统配置；USB 2.0 也能完成，只是更慢 |

---

## 7. 安装前检查清单（必须逐项确认）

> 勾选项对应“用户授权的实机安装测试”前置条件；本报告不代替用户确认。

### 7.1 主机与环境（只读）

- [ ] 关闭会占用 USB/MTP 的客户端：SwitchShelf App（尤其设备读取/探针）、Finder 的 MTP/Image Capture、Android File Transfer、Photos/Image Capture、其它 libmtp 客户端。
- [ ] 确认共享租约未被占用（只读检查）：
  - `lsof "$HOME/Library/Application Support/SwitchShelf/device-lease.lock"`（文件尚未创建或 `lsof` 无输出=空闲；有输出=另一个进程持有）
- [ ] 构建 helper：`swift build -c release --product switchshelf-backend`
- [ ] 运行只读枚举，确认 `057e:3000` 已出现且 **found=true**（不打开设备）：
  - `.build/release/switchshelf-backend discover --wait 30 --json`
- [ ] 保存真实描述符（**discover 只证明 VID/PID，不证明 class/alt/端点**）：
  - `ioreg -p IOUSB -l -w 0 > /tmp/switchshelf-057e3000-ioreg.txt`（或按本机 macOS 使用 `ioreg -r -c IOUSBHostDevice -l -w0` / `system_profiler SPUSBDataType`）
  - 核对：`idVendor=0x057e`、`idProduct=0x3000`、interface `bInterfaceClass=0xff`、`bAlternateSetting=0`、恰好 2 个 bulk 端点 `0x01`(OUT)/`0x81`(IN)。
- [ ] 确认没有同时出现 `057e:201d`（MTP）会话；不要在 Backend 模式下运行 MTP 读取。
- [ ] 记录当前 DBI 状态截图/照片（版本 `647-zhcn`、固件显示 `19.0.1e`：两者目前是用户报告，不是自动验证字段）。

### 7.2 源文件（只读，以 task-2 从数据库取得的精确路径为准）

- [ ] 路径为绝对路径，且不包含 `..`。
- [ ] `stat -f 'name=%N size=%z type=%HT mode=%Sp' "/Volumes/switch 游戏包/未命名鹅游戏 Untitled Goose Game/Untitled Goose Game [010082400BCC6000][v0].nsp"`：普通文件、可读、大小 834,297,609 字节（task-2 已只读核实；若库/文件有变化以重新扫描结果为准）。
- [ ] 不是符号链接（lstat/`readlink` 确认；路径祖先目录也应为真实目录）。
- [ ] basename 可作为 Backend 文件名：UTF-8、无路径分隔符/冒号/控制字符/换行；扩展名属于 `.nsp/.xci/.nsz/.xcz`；行文与 DBI 清单中显示的一致。
- [ ] 源文件在传输过程中不会被其他进程修改/移动（SMB 断连或库刷新会导致 `sourceChanged`）。
- [ ] 记录当前 SMB 挂载状态与可用磁盘/时间；预计 834 MB 传输 + 安装需要十几分钟到数十分钟。

### 7.3 Switch / DBI 屏幕（用户确认）

- [ ] DBI 主菜单可见 **Install title from DBIbackend**（`BackendInstall` 未被关闭；README 示例默认 `true`）。
- [ ] 按 **(Y)** 进入 Backend 模式；确认主机 `discover` 看到 `057e:3000`。
- [ ] DBI 上能看到主机发来的文件清单，且 **basename 与源文件完全一致**（逐字/UTF-8）。
- [ ] 选择该 NSP。
- [ ] 观察设备端是否出现 **Target（SD/NAND）选择**；若出现则选 **SD**；若未出现，记录实际流程（647-zhcn 的 Backend 安装是否提供目标选择目前未知，不要假设）。主机不能设置或验证目标，注意文案可能是中文。
- [ ] SD 剩余空间足够（任务 2 的估算 ≥1.5 GB；以 DBI 屏幕显示的 SD 容量为准）。
- [ ] 开始安装，并保持数据线/电源稳定；不要在传输中拔线、切模式或操作其他 USB 客户端。

### 7.4 helper 参数（一次尝试）

```sh
cd /Users/jiazi/Desktop/SwitchShelf
.build/release/switchshelf-backend install \
  --file "/Volumes/switch 游戏包/未命名鹅游戏 Untitled Goose Game/Untitled Goose Game [010082400BCC6000][v0].nsp" \
  --wait 300 \
  --timeout 3600 \
  --chunk 1048576 \
  --target sd \
  --journal "$HOME/Library/Application Support/SwitchShelf/backend/journal.json" \
  --json
```

- `--target sd` 只是本地意图记录，**不会**发给设备。
- `--timeout` 建议 1800–3600 s（默认 1800）；`--chunk` 建议 1 MiB 起步（默认 256 KiB）。
- 先启动 helper（它会等待设备），再在 DBI 选择 Backend 入口；顺序反了也可，helper 最长等 `--wait` 秒。
- 记录 stdout（JSON 报告）与 stderr（进度/等待消息）。

### 7.5 记录与留证

- [ ] helper JSON（outcome、uniqueBytesSent、peerRequestedExit、attemptID、journal 路径/状态）。
- [ ] helper stderr（等待/进度/错误）。
- [ ] journal 文件（`~/Library/Application Support/SwitchShelf/backend/journal.json`）副本。
- [ ] `/tmp/switchshelf-057e3000-ioreg.txt` 描述符输出。
- [ ] DBI 屏幕照片/视频：清单、文件名、Target=SD、进度、完成/错误提示。
- [ ] 用户对“安装完成/失败”的明确口述或文字确认，含时间戳。
- [ ] 安装后在 DBI **Browse installed applications** 或 HOS 主界面核对标题确实出现。

---

## 8. 建议的失败处理

| 现象（主机/设备） | 含义 | 主机侧动作 | 设备侧确认 | 是否自动重试 |
|---|---|---|---|---|
| `discover` exit 3 / found=false | 未看到 057e:3000 | 不要启动 install；确认 DBI 已进入 Backend 模式、线缆/端口、设备是否处于 MTP/普通模式 | DBI 屏幕是否显示 Backend 模式 | 否；人工排查后可重跑 discover |
| install exit 4 / deviceBusy | 共享租约被占用 | 关闭 SwitchShelf App/探针/MTP 客户端；确认 `lsof` 无占用后重跑 | — | 否 |
| install exit 3 / deviceUnavailable | 无/多个 057e:3000，或描述符/接口打开失败 | 保存 ioreg；核对 class/alt/端点；不要绕过校验 | 确认设备模式 | 否；把描述符差异作为独立问题 |
| install exit 1（预检失败） | 路径/文件名/大小/可读性/清单长度问题 | 按 notes 修复源文件条件后重跑 | — | 否 |
| `protocolViolation` / `unsupportedCommand` | 设备包与仓库假设不一致（ACK/type/nameLen/命令） | 停止；保存 JSON/stderr/journal/原始 ACK（若已记录）；按 §5/P0-1 分析 | DBI 屏幕是否有传输错误 | **否**；盲重试无益 |
| `timeout` / `disconnected` / `transport`（exit 2 或 1） | 传输中断；安装结果**未知** | 不宣称失败或成功；保存证据；确认没有挂起进程 | 先看 DBI 屏幕：仍在安装则等待；已回主菜单则记录状态 | 否；由用户重新进入 Backend 模式后**人工**重跑 |
| EXIT 但覆盖不完整（exit 2） | 设备提前结束或部分未发送 | 记录“未知”；不要当成成功 | DBI 是否显示错误/中止 | 否 |
| exit 5 / journalUnavailable | 主机证据落盘失败 | 检查 journal 路径/权限/磁盘；设备结果未知 | 设备屏幕 | 否 |
| exit 124（硬超时，CLI 约定） | 会话/等待超预算 | 保存证据；设备结果未知 | 检查 DBI 状态 | 否 |
| exit 130 | 用户取消 | 释放连接；设备结果未知 | 检查 DBI 状态 | 否 |
| 主机崩溃/被 kill | 传输可能在任意点中断 | 重启后 journal 中活动 attempt 会变为 interrupted；不自动恢复 | 设备可能仍在安装/等待，先看屏幕 | 否 |

通用规则（与 AGENTS.md 一致）：

1. **不做盲重试**：断开/超时后设备是“未知”，不是“失败”；重跑前必须让用户重新确认设备状态。
2. **不删除/格式化/改存档**：失败处理不删除已安装游戏、不改设备配置、不格式化 SD。
3. **不与 MTP 并发**：同一设备同一时间只能有一个 Backend 或 MTP 会话；App 的 MTP 读取/探针必须停止。
4. **不把 EXIT/journal finished/exit 0 当安装成功**；成功只以设备端显示为准。
5. **不修改设备配置来“救场”**（例如临时改 `dbi.config`），除非用户另行明确授权。

---

## 9. 安装成功的判定（主机协议之外）

1. 主机侧最强证据只是：**设备请求了 EXIT，且主机完整发送了设备请求的全部范围字节**（helper `outcome = transferredAwaitingConfirmation`，exit 0）。
2. 真正成功需要设备端证据链：
   - DBI 安装进度到 100% 且出现完成提示（而非 `Transfer error`/`TRANSFER CRC ERROR`/`TRANSFER ABORTED`）；
   - DBI **Browse installed applications** 中出现该标题（README B 小节），或 HOS 主界面出现该游戏图标；
   - 用户明确确认并记录时间。
3. 任何一环缺失都应写“未知”，不得写“已安装”。

---

## 10. 给 Lead 的优先建议

1. **P0（首跑成功率）**：决定 ACK 兼容策略。推荐首跑按官方行为（读完 16 字节但不因 length 字段/字段值中止），或至少记录原始 ACK 并以失败日志判断；否则 FILE_RANGE ACK 的未知 length 可能让首跑在发数据前失败。
2. **P0（安全边界）**：安装前先做 `discover` + `ioreg` 描述符取证；描述符不符就停止并上报，不绕过 `bridge.c` 校验。
3. **P1（性能/时长）**：首跑用 `--chunk 1048576`，`--timeout 3600`；记录总时长、命令数、SMB 读延迟。
4. **P1（命令预算）**：若观察到 range 偏小（如 16 KiB）或进度 ~98% 后超时，把 helper 的 `maximumCommands` 从 50,000 提到 100,000。
5. **P1（现场）**：用户必须在 DBI 屏幕确认 Target=SD 与安装结果；主机侧不能替代。
6. **P2（结论更新）**：本次无论成败，都应把实机观测（描述符、ACK 字节、range 大小、EXIT 时机、设备提示）回填到本报告或新报告，再把“647-zhcn 已验证”从未知项中移除。
7. 本报告**未修改任何源码/测试/Package.swift/其他文档**；是否需要调整 `BackendSession`/helper 属于 Lead 的实现范围。

---

## 附录 A：复现命令与哈希

```sh
# 1) 取得固定提交的官方脚本（本环境 web_fetch 因 non-public IP 失败，使用直连 curl）
curl -sS -o /tmp/dbibackend.curl.txt \
  'https://raw.githubusercontent.com/rashevskyv/dbi/22090afc64cc7b5d645a99bf3d4d8625a67b766e/dbibackend'

# 2) 校验脚本身份
git hash-object /tmp/dbibackend.curl.txt
# 85e7285e92313b5ee262e52ec5b41e31fc88f622
shasum -a 256 /tmp/dbibackend.curl.txt
# 0202d4ab2cfdd281762180d3deb1862558ccafa477ba0ccd104cc3a9ae9b7c64

# 3) 用 GitHub API 交叉核对固定提交的内容
curl -sS 'https://api.github.com/repos/rashevskyv/dbi/contents/dbibackend?ref=22090afc64cc7b5d645a99bf3d4d8625a67b766e'
# sha 85e7285e92313b5ee262e52ec5b41e31fc88f622, size 7715

# 4) 该脚本的修改历史（最后一次改动）
curl -sS 'https://api.github.com/repos/rashevskyv/dbi/commits?path=dbibackend&per_page=8'
# a52a584e99e6 2023-10-26 "DBI 616"（该提交处 blob 仍为 85e7285e…，size 7715）

# 5) 固定提交 README（B 级证据）
curl -sS -o /tmp/dbi-README-22090af.md \
  'https://raw.githubusercontent.com/rashevskyv/dbi/22090afc64cc7b5d645a99bf3d4d8625a67b766e/README.md'
git hash-object /tmp/dbi-README-22090af.md   # 89cc69da63fd9f8aa0976b6130264bce9a56352e
shasum -a 256 /tmp/dbi-README-22090af.md     # da6459cb310525dbab294978f709deb4903951ffe45d3e41ce8548d9ae76fc48
diff -q /tmp/switchshelf-dbi-README.md /tmp/dbi-README-22090af.md   # 无差异
```

> `/tmp` 下的脚本/README 是临时只读检查副本，不在仓库内、不随报告分发；仓库中只保留独立转述。

## 附录 B：官方主机行为独立转述（非原脚本复制）

```text
常量: 16B 头 = "DBI0" | type:u32 | cmd:u32 | len:u32 (LE)
      type: 0=REQUEST 1=RESPONSE 2=ACK
      cmd: 0=EXIT 1=LIST_OLD(未实现) 2=FILE_RANGE 3=LIST
      SEG = 0x100000 (1 MiB)
loop:
  header = read16()                    # 无/DBI0 之外的 magic 忽略
  case cmd:
    EXIT:    write16(RESPONSE, EXIT, 0); quit host
    LIST:    text = concat(basename+"\n") as UTF-8
             write16(RESPONSE, LIST, len(text))
             if len(text) > 0: read16_ack_ignored(); write(text)
    FILE_RANGE:
             write16(ACK, FILE_RANGE, header.len)      # 先 ACK 再收负载
             payload = read_exactly(header.len)
             size:u32@0, offset:u64@4, nameLen:u32@12, name=UTF8@16..
             # nameLen 打印但不校验；name 取第 16 字节后的全部
             write16(RESPONSE, FILE_RANGE, size)
             read16_ack_ignored()
             for seg in <=1 MiB pieces until size consumed:
                 write(file_bytes)                     # 无逐块 ACK，不节流
  on USBError: wait for device to re-enumerate; do not retry the command
```

## 附录 C：本任务要求项的对应位置

| 要求核对项 | 本报告位置 |
|---|---|
| 16 字节头布局 | §2.1、§3 #2 |
| type(0/1/2) | §2.1、§3 #3 |
| command(EXIT=0/FILE_RANGE=2/LIST=3 与 legacy LIST=1) | §2.1、§3 #4、§5 P2 |
| payload 长度字段 | §2.1、§3 #5 |
| ACK 流程（LIST/FILE_RANGE 各自） | §2.2、§3 #8/#10/#14、§5 P0-1 |
| FILE_RANGE 请求负载格式 | §2.2、§3 #11 |
| 文件清单位置（谁先发起 LIST） | §2.2、§3 #6 |
| EXIT 触发时机与语义 | §2.2、§2.4、§3 #16/#19、§6 |
| 分块大小/写入节奏 | §2.1、§2.2、§3 #15、§5 P1-2 |
| 超时/重试行为 | §2.3、§3 #17、§5 P1-1 |
| 目标(SD/NAND)选择/安装结果回报 | §2.4、§3 #18/#19、§9 |
| PID/VID/interface 假设 | §2.1、§3 #1、§5 P0-2、§6 |
| 与仓库实现/测试对照 | §3 全表、§1.3 |
| 证据等级区分 | §0.3、§1 |
