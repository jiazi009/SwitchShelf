# Backend 实机安装现场测试计划（单个候选包）

- 文档状态：**计划与只读预检已完成；尚未执行任何安装、传输或设备写入。本文件不构成执行授权。**
- 预检时间：2026-10-23 23:38–23:41（+08:00，Asia/Shanghai）
- 仓库状态：`main` @ `6cf930e`（另见 §2 中 helper 仍在开发中的事实）
- 授权范围（用户已确认部分）：用户已授权**安装一个游戏**。本计划仅覆盖：在另行确认的测试窗口内，用 DBI Backend 主机协议把**下面唯一一个**候选包安装到 **SD**。
- 本计划之外仍然只读：不切换 DBI 模式作演示、不运行真实传输（除本次授权窗口）、不改配置、不删除设备对象、不碰存档、不格式化、不修改/移动/重命名/上传源游戏包、不完整哈希大文件。
- 依据文档：[Backend 协议核对](../Reports/backend-protocol.md)、[Backend USB 适配器任务边界](backend-usb.md)、[MTP 存储诊断（Installed games 不可用）](../Reports/mtp-storage-diagnosis.md)、[Backend 基础验收](../Reports/backend-foundation-acceptance.md)、[项目交接](../Reports/project-handoff.md)、[架构](../ARCHITECTURE.md)、[AGENTS.md](../../AGENTS.md)。
- 官方协议参照（pinned）：[`rashevskyv/dbi` `dbibackend` @ `22090afc64cc7b5d645a99bf3d4d8625a67b766e`](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/dbibackend)、[DBIbackend 安装说明](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/README.md#install-title-from-dbibackend)。

---

## 0. 结论摘要（先读）

1. **候选包已只读核实**：`/Volumes/switch 游戏包/…/Untitled Goose Game [010082400BCC6000][v0].nsp`，834,297,609 字节，普通文件（非符号链接），`stat` 大小与 DB `byte_count` 一致。
2. **当前设备处于 MTP 模式**：仅存在 `057e:201d`（ioreg 显示 `idVendor=1406`、`idProduct=8221`、产品名 `DBI`），接口 `class=6/1/1`、3 个端点，被系统 `ptpcamerad` 独占。**没有 `057e:3000` Backend 设备**。Backend helper 的 C 适配器只接受 `057e:3000 + class 0xff + alt 0 + 2 个 bulk 端点（OUT 0x01 / IN 0x81）`，会拒绝 MTP 设备；这正是预期行为，不要绕过。
3. **SwitchShelf app 当前正在运行**（PID 67018），已打开 `library.sqlite` 及其 WAL。`device-lease.lock` 当前**没有**被打开（`lsof` 无持有者），但 app 在测试前必须退出，避免它在窗口内抢设备租约或做设备读取。
4. **源文件在 SMB 挂载上**（`//jiazi@192.168.62.4/switch%20%E6%B8%B8%E6%88%8F%E5%8C%85` → `/Volumes/switch 游戏包`，`smbfs`，本机经有线 `en0`/`192.168.62.6` 访问）。本次安装会持续读取 SMB 上的 834 MB；SMB 抖动、重连或元数据变化会触发 `sourceChanged`（正确行为，应中止）。
5. **helper（task-3）在预检结束（23:41）时尚未就绪**：当时 `Package.swift` 有未提交改动、`Sources/SwitchShelfBackendInstall/` 已存在但未见 CLI target 文件、无可执行产物。预检后 Lead 继续推进（23:45 复核已看到 `Sources/SwitchShelfBackendCLI/main.swift`、`InstallRun.swift`、测试与 helper 报告文件），但**尚未确认构建/测试通过**；执行本计划前必须先完成 §2 的“helper 就绪门禁”。
6. **`EXIT` 只表示设备请求结束，不等于安装成功。** 安装是否成功只能由用户在 DBI 本机“浏览已安装的应用程序”观察确认；MTP 的 Installed games 入口当前不可用，不能作为主机侧验证通道。

---

## 1. 候选包与“唯一文件”锁定（只读证据）

### 1.1 数据库来源（本次预检实际执行的只读查询）

```bash
DB="$HOME/Library/Application Support/SwitchShelf/library.sqlite"
sqlite3 -readonly -header -column "$DB" "
SELECT c.id, g.title, c.title_id, c.kind, c.byte_count, c.format, c.availability, c.file_url
FROM contents c JOIN games g ON g.id = c.game_id
WHERE c.title_id = '010082400BCC6000' AND c.kind = 'base';"
```

结果（原样记录）：

| 字段 | 值 |
|---|---|
| game | `未命名鹅游戏`（Untitled Goose Game） |
| contents.id（解码后的绝对路径） | `/Volumes/switch 游戏包/未命名鹅游戏 Untitled Goose Game/Untitled Goose Game [010082400BCC6000][v0].nsp` |
| title_id / kind / format | `010082400BCC6000` / `base` / `nsp` |
| byte_count | `834297609` |
| availability | `online` |
| file_url（DB 原样，percent-encoded） | `file:///Volumes/switch%20%E6%B8%B8%E6%88%8F%E5%8C%85/%E6%9C%AA%E5%91%BD%E5%90%8D%E9%B9%85%E6%B8%B8%E6%88%8F%20Untitled%20Goose%20Game/Untitled%20Goose%20Game%20%5B010082400BCC6000%5D%5Bv0%5D.nsp` |

同一游戏存在更新包（`kind=update`，`byte_count=375633682`，`[UPD][v1.1.2]…[v458752][US].nsp`），**本计划不安装更新/DLC，只安装上面的本体 NSP**。安装后 DBI 可能提示“有更新”——不处理。

### 1.2 文件系统证据（`stat`/`ls`/`file`，未读内容、未哈希）

```bash
P="/Volumes/switch 游戏包/未命名鹅游戏 Untitled Goose Game/Untitled Goose Game [010082400BCC6000][v0].nsp"
stat -f 'mode=%Sp size=%z dev=%d ino=%i links=%l' "$P"
stat -f 'mtime=%Sm ctime=%Sc' -t '%Y-%m-%dT%H:%M:%S%z' "$P"
file "$P"; df -h "/Volumes/switch 游戏包"; mount | grep 'switch 游戏包'
```

本预检实际结果：

| 证据项 | 值 | 判定 |
|---|---|---|
| 绝对路径 | `/Volumes/switch 游戏包/未命名鹅游戏 Untitled Goose Game/Untitled Goose Game [010082400BCC6000][v0].nsp` | 存在 |
| 类型 | `stat` mode `-rwx------`，`links=1`；`os.path.islink=False`、`isfile=True`；`file` 识别为 `Nintendo Switch partition filesystem (PFS0), 7 files` | **普通文件，非符号链接** |
| 大小 | `834297609` 字节 = 795.6 MiB ≈ 0.834 GB（十进制） | 与 DB `byte_count` 完全一致 |
| 可读性 | `test -r` → yes；属主 `jiazi`，mode 0700 | helper 可只读打开 |
| 时间/身份 | `mtime=ctime=2025-06-19T20:01:33+0800`，`dev=905969671`（SMB），`ino=5390` | reader 绑定证据用；SMB 重连会改变 `dev` |
| 文件系统 | `smbfs`，挂载点 `/Volumes/switch 游戏包`，DF 930Gi/164Gi avail | 只读源；网络依赖 |
| basename | `Untitled Goose Game [010082400BCC6000][v0].nsp` | 见 §1.3 |

**明确不做**：不读取整包内容、不 `shasum`/`xxd`/`cat` 大文件、不复制到本地、不移动/重命名/删除源文件。`file` 只读文件头，可接受；除此之外不碰内容。

### 1.3 Backend 文件名安全检查（与 `BackendPreflight` 规则一致）

| 检查 | 结果 |
|---|---|
| UTF-8 字节数 | 46（上限 255） |
| 扩展名 | `nsp`（允许 `nsp/xci/nsz/xcz`） |
| 路径分隔符 `/`、`\` | 无 |
| `:` | 无 |
| 控制字符/换行 | 无 |
| `.` / `..` | 否 |
| LIST 载荷 | 46+1 = 47 字节（含 LF；上限 65,536） |

DB 的 `contents.id` 恰好是解码后的绝对路径，但**安装 helper 不依赖把不透明 ID 当路径解释**：本次直接把 `--file` 指向上面核实过的绝对路径；Backend 文件名由 helper 取 basename（当前 CLI 无 `--name`）。文件名中的 `[010082400BCC6000]` 只是候选身份，**不是内容验证结果**（不做哈希）。

---

## 2. 当前环境快照与“helper 就绪门禁”

### 2.1 USB 描述符（`ioreg`，只读，预检时）

| 项 | 预检值（2026-10-23 23:38–23:41） |
|---|---|
| Backend 候选 `057e:3000` | **不存在**（idProduct 列表：32779、32780、32913、1411、20592、8221；无 12288） |
| 现有 Switch 设备 | `USB Product Name="DBI"`，`idVendor=1406`（0x057E），`idProduct=8221`（0x201D），`USB Serial Number=XKC10009957304`，`locationID=35782656`（0x02220000） |
| 现有接口 | `DBI MTP@0`，`bInterfaceClass=6`、`bInterfaceSubClass=1`、`bInterfaceProtocol=1`，`bNumEndpoints=3`，`UsbExclusiveOwner="pid 52335, ptpcamerad"` |
| 总线位置 | `AppleT8132USBXHCI` → `USB3 Gen2 Hub@02200000` → `DBI@02220000`；设备 `bcdUSB=768 (0x0300)` |
| 结论 | 当前是 MTP，不是 Backend；Backend helper 打开前必须看到 `057e:3000` |

复检命令（预检/执行前后都用同一命令，保证可比）：

```bash
ioreg -p IOUSB -w0
ioreg -r -c IOUSBHostDevice -l -w0 | grep -E '"(USB Product Name|idVendor|idProduct|bInterfaceClass|bInterfaceSubClass|bInterfaceProtocol|bNumEndpoints|bAlternateSetting|bInterfaceNumber|UsbExclusiveOwner|USB Serial Number)"'
```

执行期期望：设备从 `057e:201d`（MTP）重枚举为 `057e:3000`（Backend）；若出现多个 `057e:3000`、或 class/alt/端点不符，helper 会拒绝，见 §5。

### 2.2 进程 / 租约 / App 状态

| 项 | 预检值 |
|---|---|
| SwitchShelf app | **运行中**，PID 67018（`build/SwitchShelf.app/Contents/MacOS/SwitchShelf`），已打开 `library.sqlite`/`-wal`/`-shm` 文件描述符 |
| `device-lease.lock` | 存在：`~/Library/Application Support/SwitchShelf/device-lease.lock`，0 字节，mtime `2026-10-23T23:32:10+0800`；`lsof` **无持有者** → 当前空闲 |
| `switchshelf-probe` | 未运行 |
| 其他 MTP 客户端 | 未发现 Android File Transfer / OpenMTP / MacDroid / Image Capture / QuickTime 等；仅有系统 `ptpcamerad`(52335) 与 `icdd`(2272) |
| `install-plan.json` | `[]`（已清空） |
| `backend/journal.json` | **尚不存在**（`~/Library/Application Support/SwitchShelf/backend/` 未创建） |

复检命令：

```bash
pgrep -fl 'SwitchShelf|switchshelf-probe|switchshelf-backend|Android File Transfer|OpenMTP|MacDroid'
lsof "$HOME/Library/Application Support/SwitchShelf/device-lease.lock"
ls -la "$HOME/Library/Application Support/SwitchShelf"
```

### 2.3 helper 就绪门禁（执行前必须全部满足）

预检时事实：`main @ 6cf930e`；工作树存在 `M Package.swift`、`?? Sources/SwitchShelfBackendInstall/`；当时**没有** `switchshelf-backend` 可执行文件。预检后（23:45）Lead 的 CLI/测试/报告文件已出现，但尚未构建/测试取证。因此：

- [ ] task-3 已完成并由 Lead 报告：`swift build` 通过、`swift test`（含 `SwitchShelfBackendInstallTests`）通过。
- [ ] 可执行产物存在（由 Lead 在测试窗口**之前**构建，传输窗口内不构建）：
      ```bash
      swift build -c release --product switchshelf-backend
      .build/release/switchshelf-backend install --help    # 实际路径以 swift build 输出为准
      ```
- [ ] 用 `--help` 复核当前 CLI（预检时从 `main.swift` 读到，最终以构建出的二进制为准）：
      `install --file <绝对值> [--wait 300] [--timeout 1800] [--journal <path>] [--chunk 262144] [--target sd|nand] [--json|--no-wait]`；
      另有 `discover --wait <s> --json`（只读枚举，不打开设备）。
      **注意：当前实现没有 `--name` 参数，Backend 文件名取自 `--file` 的 basename**；本次 basename 已核对（§1.3），无需改名。
- [ ] 记录被测二进制证据：`git rev-parse HEAD`、二进制路径、`shasum -a 256 .build/release/switchshelf-backend`（小文件哈希允许）、`--help` 全文。
- [ ] 确认执行环境 **不设置** `SWITCHSHELF_DEVICE_LEASE_PATH`（`printenv SWITCHSHELF_DEVICE_LEASE_PATH` 应为空/不存在），确保 helper 与 app/probe 使用同一把 `device-lease.lock`。
- [ ] Lead 已确认 helper 行为：失败/取消时只关闭一次传输且不自动重试；`releaseUnverified` 会永久拒绝新会话；退出码见 §4.6。
- [ ] §9 的用户确认事项已逐条勾选。

> 门禁任一未满足：**不进入 §4 的任何一步**，等 Lead 更新后再重新预检。

---

## 3. 前置条件（现场 checklist）

### A. 用户 / Switch 侧

- [ ] DBI **647-zhcn**、系统 **19.0.1e**（沿用用户已报告版本；不要求重复升级/换卡）。中文构建的菜单文案可能不同，**以设备实际屏幕为准，不猜菜单名**。
- [ ] 数据线/接口保持今天 MTP 可用的同一根线与同一个口（当前经 `USB3 Gen2 Hub`），测试中途不换口、不换线、不经过新的扩展坞。
- [ ] Switch 已从 **MTP 模式退出到 DBI 主菜单**（当前会话是 MTP，不能直接进入 Backend）。
- [ ] 从 DBI 主菜单**按 Y** 进入 **“Install title from DBIbackend”**（英文原版文案；中文构建按实际屏幕）。
- [ ] **SD 卡剩余空间 ≥ 1.5 GiB**（≈1.61×10⁹ 字节）。估算：本次本体 `834,297,609 B ≈ 795.6 MiB`，约 2× 余量；若用户坚持同时装更新包（`375,633,682 B ≈ 358 MiB`），总量约 1.13 GiB，1.5 GiB 余量偏紧——本计划**只装本体**，不装更新。
- [ ] 在 DBI 安装界面把 **Target = SD** 选中并能在屏幕上确认；如果版本没有可见/可确认的目标选择，**在中止表中按“目标无法确认”处理**（主机协议没有设置目标的命令，无法代用户强制）。
- [ ] Switch 不进入睡眠、不按 Home/待机、不拔线。
- [ ] 现场只有一名操作者（用户或 Lead）；助手侧/主机侧任何“重试”都要先停下来重新授权。

### B. Mac 侧

- [ ] **退出 SwitchShelf app**（Cmd+Q，不是强杀），并验证：
      ```bash
      pgrep -fl 'SwitchShelf|switchshelf-probe|switchshelf-backend'   # 期望：除将要启动的 helper 外为空
      lsof "$HOME/Library/Application Support/SwitchShelf/device-lease.lock"  # 期望：无输出
      ```
      若 app 无法正常退出 → 中止测试，不在 app 运行时安装。
- [ ] 关闭会抢 MTP/USB 的客户端：Image Capture、Photos、QuickTime Player、Android File Transfer、OpenMTP、MacDroid、Chrome/Edge 上的 WebUSB 页面等；**不要**杀 `ptpcamerad`/`icdd` 系统进程（MTP 模式下接口由 `ptpcamerad` 独占是正常现象；Backend 模式 `0xff` 类不会被它认领）。
- [ ] 测试窗口内**不运行** `switchshelf-probe`、App 设备读取或其他 MTP 客户端。
- [ ] Mac 不睡眠：使用 `caffeinate -dimsu` 包裹 helper 或临时保持唤醒；插电优先。
- [ ] 网络：有线 `en0`（本机 `192.168.62.6`）访问 NAS `192.168.62.4`；source 挂载保持 `online`。**SMB 抖动会触发 `sourceChanged`/超时，属正确中止，不重试**。
- [ ] 不 `sudo` 运行 helper（保持用户会话与租约文件属主；不需要 root）。
- [ ] 证据目录：`output/diagnostics/backend-install-<UTC时间戳>/`（沿用既有忽略目录 `output/diagnostics/`，权限 0700）；**现在不创建**，执行时由操作者创建。

### C. 源文件 / 台账

- [ ] §1 的 `stat` 证据不变：`size=834297609`、普通文件、非符号链接、`availability=online`。
- [ ] helper 的 `--file` 使用 §1.2 的**绝对路径**；helper 取到的 basename 必须等于 §1.3 的 basename；不改名、不复制到本地。
- [ ] 不运行任何“预检测试传输”；本次唯一真实传输就是授权的那一次。

---

## 4. 执行步骤（主机 / Switch 交替；按顺序）

> 全程一个终端；命令里 `$HELPER`、`$P`、`$EVID` 由操作者按实际路径设置。以下命令在授权窗口内执行；其中**只有 helper 与证据写入**，没有 App、没有 probe。

### 4.0 阶段 0：冻结环境、采集 before 证据

```bash
set -o pipefail
EVID="$PWD/output/diagnostics/backend-install-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EVID" && chmod 700 "$EVID"
P="/Volumes/switch 游戏包/未命名鹅游戏 Untitled Goose Game/Untitled Goose Game [010082400BCC6000][v0].nsp"

date '+%Y-%m-%dT%H:%M:%S%z'                                    | tee "$EVID/env-before.txt"
ioreg -p IOUSB -w0                                              | tee -a "$EVID/env-before.txt"
ioreg -r -c IOUSBHostDevice -l -w0 \
  | grep -E '"(USB Product Name|idVendor|idProduct|bInterfaceClass|bNumEndpoints|UsbExclusiveOwner)"' \
                                                                 | tee -a "$EVID/env-before.txt"
pgrep -fl 'SwitchShelf|switchshelf-probe|switchshelf-backend'   | tee -a "$EVID/env-before.txt"
lsof "$HOME/Library/Application Support/SwitchShelf/device-lease.lock" | tee -a "$EVID/env-before.txt"
stat -f 'size=%z mode=%Sp links=%l dev=%d ino=%i' "$P"          | tee -a "$EVID/env-before.txt"
git rev-parse HEAD                                              | tee -a "$EVID/env-before.txt"
```

**门禁（全部满足才继续）**：
- [ ] `057e:3000` 不出现；只有 `057e:201d`；无 App/probe/helper 进程；lease 无持有者；`stat` 与 §1.2 一致；`$P` 可读。
- 任一不符 → **中止**（§5），记录 `env-before.txt`。

### 4.1 阶段 1：启动 helper 等待 Backend 设备（主机）

```bash
set -o pipefail   # 在 bash 或 zsh 下都可用；下面用 $? 取 helper 的退出码
$HELPER install \
  --file "$P" \
  --wait 300 \
  --timeout 1800 \
  --target sd \
  --json 2>&1 | tee "$EVID/helper.log"
echo "helper_exit=$?" | tee -a "$EVID/helper.log"
```

说明：
- helper 默认最多等待 **300 s** 让 `057e:3000` 出现；`--no-wait` 只在“设备已经处于 Backend 模式后”使用，本计划**不用** `--no-wait`（默认等待更稳）。
- 当前 CLI 无 `--name`；Backend 文件名取自 `--file` 的 basename（已核对，见 §1.3）。
- helper 在设备出现前只做只读 IOKit 枚举/等待，不打开设备；`057e:201d` 不会被当作 Backend（C 适配器精确匹配，见 §2.1）。
- `--json` 只是兼容参数，helper 始终输出 JSON 报告；进度行打印在 stderr（`\r主机侧进度 N%`），`2>&1 | tee` 可同时留证。
- 若 helper 以 `deviceBusy`（退出码 4）立即结束：有进程持有租约 → 回查 §2.2，**不要 kill 持锁进程**；中止。
- 300 s 内设备未出现 → helper 以 `deviceUnavailable`（退出码 3）结束 → 按 §5 处理，**不自动重启 helper**。

### 4.2 阶段 2：Switch 进入 Backend 模式

- [ ] 用户在 DBI 主菜单**按 Y** 进入 “Install title from DBIbackend”；屏幕进入等待/传输界面。
- [ ] 设备重枚举：主机端 helper 日志应出现“发现 Backend 候选 / 预检通过 / 会话开始”等记录（以 helper 实际文案为准）。
- [ ] 可在**另一个终端**只读复核描述符（不参与传输、不打开设备）：
      ```bash
      ioreg -r -c IOUSBHostDevice -l -w0 | grep -E '"(USB Product Name|idVendor|idProduct|bInterfaceClass|bAlternateSetting|bNumEndpoints)"'
      # 期望看到 057e:3000、class 0xff、alt 0、2 个 bulk 端点 0x01/0x81
      # 也可用（只读枚举、不打开设备）：.build/release/switchshelf-backend discover --wait 30 --json
      ```
      若描述符不符 → helper 会拒绝并退出；**不要**改 helper、不要 seize/reset 设备、不要尝试第二次打开。

### 4.3 阶段 3：设备侧文件列表与选择

- [ ] DBI 屏幕出现主机提供的文件列表，**必须只有 1 项**：`Untitled Goose Game [010082400BCC6000][v0].nsp`。
- [ ] 列表为空、出现多余项、或文件名与上面不一致 → **中止**（主机只 offer 了这一个文件；不一致是协议/预检异常）。
- [ ] 用户选中该唯一文件。

### 4.4 阶段 4：设备侧 Target 与开始

- [ ] 屏幕 **Target = SD**，截图/拍照留证。
- [ ] 用户确认“开始安装”（按 DBI 提示操作）。
- [ ] 主机端开始传输；`--timeout 1800` 是本次会话预算（helper 默认 `sessionTimeoutSeconds=1800`、单次 I/O 15 s、块 256 KiB；以 `--help`/代码为准）。
- [ ] 传输期间：不碰线、不睡眠、不启动其他 USB/MTP 客户端、不按 Switch 的 Home/待机；不要 `kill -9` helper。

### 4.5 阶段 5：观察进度（主机 + 设备）

进度只看两处，且都只是**主机侧覆盖量**：

```bash
J="$HOME/Library/Application Support/SwitchShelf/backend/journal.json"
# 每 ~10–15 秒一次，只读
python3 - "$J" <<'PY'
import json,sys,datetime
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("journal not readable yet:",e); raise SystemExit(0)
a=d["attempts"][-1]
f=a["files"][0]
print(datetime.datetime.now().isoformat(timespec="seconds"),
      a["state"], f["phase"], f["uniqueBytesSent"], "/", f["byteCount"],
      "total=",a["totalBytesSent"], "exit=",a["peerRequestedExit"])
PY
```

- [ ] 设备侧 DBI 进度条/百分比推进；主机侧 `uniqueBytesSent` 单调增长。
- [ ] helper 的 stderr 也会打印 `\r主机侧进度 N% sent/total 字节`（`tee` 日志里可查）。
- [ ] 期望最终 `uniqueBytesSent == 834297609`、`phase=transferredAwaitingConfirmation`。**这只表示主机把设备请求的字节都发出去了，不表示设备安装成功。**
- 参考耗时：0.78 GiB 经 USB（当前为 USB3 路径；实际 DBI 速率未知）+ SMB + reader 逐块复核（每块重新 stat/重开路径，SMB 上较慢）。预计数十秒到数分钟；1800 s 预算充足。**不要因为“看起来慢”而重启/重插。**
- 若进度长时间不增长且无报错 → 记录时间点，按 §5“超时/无进展”处理。

### 4.6 阶段 6：结束与 helper 结果（主机）

- helper 正常结束时应打印 JSON 报告并退出；期望：
  - `outcome = transferredAwaitingConfirmation`，退出码 **0**；
  - `peerRequestedExit = true`（设备请求 EXIT 后主机回 ACK 并结束）；
  - `uniqueBytesSent == byteCount == 834297609`；
  - `journalPath = ~/Library/Application Support/SwitchShelf/backend/journal.json`，最终 journal 该 attempt 状态为 `finished`（主机侧记录）。
- 退出码对照（当前 helper 实现；实施前用 `--help`/最终构建复核）：

| 退出码 | outcome | 含义 |
|---|---|---|
| 0 | `transferredAwaitingConfirmation` | 主机覆盖完成且设备请求 EXIT；**不是安装成功** |
| 1 | `failed` | 预检/协议/读写失败等；结果未知 |
| 2 | `incompleteTransfer` | 设备结束但主机覆盖不完整；结果未知 |
| 3 | `deviceUnavailable` | 没有可用 Backend 设备 / 描述符不符 / 会话释放未确认 |
| 4 | `deviceBusy` | 租约被占 |
| 5 | `journalUnavailable` | journal 无法读/写 |
| 64 | 用法错误 | 参数问题；未访问设备 |
| 124 | 硬超时 | 会话预算 + 120 s 后强制退出；设备状态未确认 |
| 130 | `cancelled` | 用户取消；结果未知 |

- [ ] 保存 helper JSON 与日志；**不重跑**。

### 4.7 阶段 7：设备侧完成提示与安装后核对

- [ ] 用户在 DBI 屏幕看到“安装完成/成功”之类提示，或 DBI 自动退出 Backend 模式（以设备实际为准）；截图/拍照留证。
- [ ] 退出后进入 DBI **“Browse installed applications / 浏览已安装的应用程序”**，确认 `Untitled Goose Game` 出现在列表中（如显示版本，应为 v0）；截图/拍照留证。
- [ ] 若**没有**看到该游戏：状态保持 **未知**（可能是安装失败，也可能是列表/UI 延迟），**不要**在 DBI/MTP 中删除任何对象、不要格式化、不要用本 App 去“修复”；记录并交给 Lead/用户决定下一步授权。
- [ ] **不要**用 App 的 MTP 清单核对安装状态（见 §7）。

### 4.8 阶段 8：收尾

```bash
date '+%Y-%m-%dT%H:%M:%S%z' > "$EVID/env-after.txt"
ioreg -p IOUSB -w0                       >> "$EVID/env-after.txt"
pgrep -fl 'SwitchShelf|switchshelf-probe|switchshelf-backend' >> "$EVID/env-after.txt"
lsof "$HOME/Library/Application Support/SwitchShelf/device-lease.lock" >> "$EVID/env-after.txt"
cp "$HOME/Library/Application Support/SwitchShelf/backend/journal.json" "$EVID/journal-final.json"
stat -f 'journal size=%z mode=%Sp' "$HOME/Library/Application Support/SwitchShelf/backend/journal.json" >> "$EVID/env-after.txt"
```

- [ ] helper 进程已退出；**租约已释放**（`lsof` 无输出）；无残留 probe/helper。
- [ ] Switch 已退出 Backend 模式（回到 DBI 主菜单）；如需，用户再自行切回 MTP。
- [ ] 原始 journal 保留（证据，不删除）；证据目录 0700。
- [ ] 只有用户主动要求、且另行授权时才重启 App。

---

## 5. 中止 / 失败条件（检测到即停，不自动重试）

| # | 条件 | 检测方式 | 立即动作 | 记录 |
|---|---|---|---|---|
| 1 | 无 `057e:3000`（仍在 MTP `201d`） | `ioreg` 仍是 `idProduct=8221`；helper 等待超时 | 不进入 DBI 安装界面；等 helper 自己退出（300 s）；不反复按 Y / 不反复插拔 | `env-before/after`、helper.log |
| 2 | 出现多个 `057e:3000` 候选 | C 适配器 `SS_USB_AMBIGUOUS`；helper 退出 3 | 停止；不指定、不猜测设备 | ioreg、helper JSON |
| 3 | 描述符不符（class≠0xff / alt≠0 / 端点不符） | helper 退出 3 / `unavailable` | 停止；**不改代码/不 seize/不 reset** | ioreg、helper JSON、待协议一致性复核 |
| 4 | 设备仍被当作 MTP 打开 | 不可能静默发生（适配器精确匹配）；若出现即 bug | 停止并上报 | helper 日志 |
| 5 | 租约被占 `deviceBusy` | helper 退出 4；`lsof` 显示持有者 | 不 kill 持有进程；关 App/probe 后重新走门禁；本次中止 | `lsof`、ps |
| 6 | `sourceChanged`（大小/时间/设备/ inode 变化、SMB 重连） | helper 失败；reader 每块前后复核 | 停止；重新扫描/核对 §1；新一次安装需重新授权 | journal、helper JSON、`stat` 前后 |
| 7 | `shortRead` / `rangeOutOfBounds` / `unknownFile` | helper 退出 1/2 | 停止；视为失败，不重试 | helper JSON |
| 8 | `timeout` / `disconnected` / `transport` | helper 退出 1/2；DBI 可能卡住 | 停止；用户看 DBI 屏幕；**结果未知**；不重插重试 | helper JSON、journal、用户记录 |
| 9 | `protocolViolation`（ACK/命令与 pinned 证据不符） | helper 退出 1 | 停止；647 兼容性未知；交 conformance 复核 | helper JSON、终端日志 |
| 10 | journal 写失败/容量 | helper 退出 5 | 停止；不手动改/删 journal | helper JSON |
| 11 | 用户 Ctrl-C 取消 | helper 退出 130；会话只关闭一次 | 允许它自行收尾；**不 kill -9**；DBI 侧用户退出模式 | helper.log、journal |
| 12 | DBI 屏幕报错/卡住 | 用户观察 | 用户在设备上退出/返回；主机等 helper 超时或断开；不重试 | 屏幕照片、helper JSON |
| 13 | 传递中出现疑似目标错误（NAND/未选中 SD） | 设备屏幕 | 立即在设备上取消；主机侧停止 | 屏幕照片、用户确认 |
| 14 | `releaseUnverified`（无法确认会话已释放） | helper 报错；适配器拒绝新会话 | **保持围栏**：不再启动任何 Backend 会话；等用户重启 DBI/必要时重启 Mac；上报 Lead | helper JSON、环境快照 |

**统一原则**：失败/中止后主机侧不再写设备；不清除设备上的任何对象；不自动重试；一次现场测试只做一次传输尝试，重试必须重新走 §3/§9 授权。

---

## 6. 证据采集清单

| # | 证据 | 采集方式/位置 | 时点 | 备注 |
|---|---|---|---|---|
| 1 | 环境 before/after | `$EVID/env-before.txt`、`env-after.txt`（date、ioreg、pgrep、lsof、stat、HEAD） | 阶段 0 / 8 | 只读 |
| 2 | helper 终端全文 | `$EVID/helper.log`（`set -o pipefail` + `$?` 记录退出码） | 阶段 1–6 | 含退出码与进度行 |
| 3 | helper JSON 报告 | 从 `helper.log` 截取或单独文件；含 outcome/byteCount/uniqueBytesSent/peerRequestedExit/journalPath | 阶段 6 | 主机侧证据 |
| 4 | journal 初/终快照 | 默认 `~/Library/Application Support/SwitchShelf/backend/journal.json`；复制到 `$EVID/journal-final.json` 并 `stat` | 阶段 5/8 | 主机侧证据；保留原件 |
| 5 | 传输进度 | 阶段 5 的只读 python 片段输出（时间戳、phase、uniqueBytesSent） | 阶段 5 | 不伪造百分比 |
| 6 | DBI 屏幕证据 | 照片或 Switch 截屏：① Backend 模式入口 ② 文件列表（应唯一） ③ Target=SD ④ 进度 ⑤ 完成/退出 ⑥ 安装后的“已安装应用”列表 | 阶段 2–4、7 | 用户确认屏幕内容 |
| 7 | 用户口述确认 | 目标=SD、完成提示文本、是否出现任何错误、是否看到游戏列表 | 阶段 7 | 与屏幕证据互证 |
| 8 | helper 构建证据 | HEAD、二进制 `shasum -a 256`、`--help` 全文 | 门禁 | 小文件哈希允许 |
| 9 | 源文件元数据 | 阶段 0 的 `stat`（不读内容、不哈希、不复制） | 阶段 0 | 无完整哈希 |

---

## 7. 验证与限制（必须原样保留）

1. **`EXIT` 不等于安装成功。** `peerRequestedExit=true` / journal `finished` / 退出码 0 都只说明主机发出了设备请求的字节且设备请求了结束。安装结果必须由用户在 DBI 本机“浏览已安装的应用程序”观察；协议不回报安装结果。
2. **MTP Installed games 当前不可用。** 647-zhcn 的 MTP 存储列表（九项）中没有 Installed games 入口，见 [MTP 存储诊断](../Reports/mtp-storage-diagnosis.md)。因此**不能**用 App/`switchshelf-probe` 的 MTP 清单验证安装成功或失败；那会得到“未知”而非“未安装”。不要重复要求用户重开 DBI/拔插来排查该入口。
3. **Target 不能由主机强制。** pinned 主机协议没有设置目标的命令；`intendedTarget="sd"` 只是本地意向。Target=SD 只有设备屏幕证据与用户确认。
4. **文件名身份是候选，不是内容验证。** 不哈希大文件；`[010082400BCC6000]` 等 Title ID 来自文件名/DB，不构成包内容身份或安装状态证明。
5. **源在 SMB 上。** 传输期间持续读取网络文件；SMB 重连/元数据变化会触发 `sourceChanged` 中止（正确行为）。reader 每块前后复核 `stat` 并重新打开路径，SMB 上开销明显，属预期。
6. **部分传输的结果未知。** 传输中断时设备可能收到部分字节；没有主机侧协议可以用来查询或撤销。失败后不使用 DBI/MTP/App 做“清理”。
7. **硬截止限制。** 协作式取消 + 单次 I/O 超时 + 会话预算，不能强行中断已经阻塞的内核 USB 系统调用；`kill -9` 可能留下不确定的设备所有权。不要用强杀替代正常退出/超时。
8. **不做的事（再次明确）**：不删除任何设备对象；不改存档；不格式化 SD/NAND；不切换 DBI 模式做演示；不改 DBI 配置；不修改源游戏包；不给 helper 加未审查的 retry；不 sudo。
9. 本合同只覆盖**一次**、**一个文件**、**一个目标（SD）**。任何重试、换包、换目标、批量安装都需要重新预检 + 重新授权。

---

## 8. 回滚 / 清理

- **成功（用户看到游戏在 DBI 已安装列表）**：不删除已安装游戏（除非用户另行明确授权）；不格式化；不删除设备对象；helper 退出即释放租约；保留证据与原始 journal。
- **失败/中止/结果未知**：只记录与停下；不自动重试；不删除设备上的任何对象；不碰存档；不格式化；不启动 App 去“重新扫描修复”。
- **`releaseUnverified`**：不再发起任何 Backend 会话（进程围栏），直到用户重启 DBI/必要时重启 Mac，并由 Lead 复核；期间不插拔反复尝试。
- **主机清理**：确认 helper 退出、租约 `lsof` 无持有者、无残留 probe；证据目录 0700 保留；**原始 journal 不删**。
- **App 恢复**：测试结束后（若用户需要）再启动 SwitchShelf；App 只做本地/NAS 读取与 MTP，不做安装。
- **证据保留**：`output/diagnostics/backend-install-<ts>/`（git 忽略）+ `~/Library/Application Support/SwitchShelf/backend/journal.json`。`backend/journal.json` 是主机交换记录，**不是**设备安装报告。

---

## 9. 实施前必须由用户确认的事项

> 逐条勾选后才进入 §4；由 Lead 向用户转达并记录确认。

- [ ] **C1（必须）安装对象唯一且明确**：本次仅安装 `Untitled Goose Game [010082400BCC6000][v0].nsp`（834,297,609 字节，路径见 §1.2，SMB 源只读）；不装更新/DLC；不复制/改名源文件。
- [ ] **C2（必须）目标与空间**：只装到 **SD**，Target=SD 由用户在 DBI 屏幕选择并确认；用户已确认 SD 剩余空间 ≥ 1.5 GiB。
- [ ] **C3（必须）结果语义与失败处置**：接受“`EXIT`/退出码 0 ≠ 安装成功；失败或结果未知时不自动重试、不删除设备对象、不碰存档、不格式化；重试需重新授权”。
- [ ] **C4（必须）测试窗口独占**：确认时间段内退出 SwitchShelf app、不运行 probe/其他 MTP 客户端；DBI 647-zhcn / 19.0.1e 实机在位；数据线/端口与当前一致；Mac 与 Switch 全程不睡眠、不拔线。
- [ ] **C5（必须）写入与证据授权**：允许 helper 在 `~/Library/Application Support/SwitchShelf/backend/journal.json` 写 journal，并在 `output/diagnostics/backend-install-<ts>/` 保存日志/JSON/截图/照片；原始 journal 不删除。
- [ ] C6：允许在 DBI 屏幕拍照/截屏作为安装结果证据（安装后“浏览已安装的应用程序”）。
- [ ] C7：本计划不包含“删除/卸载已安装游戏”；若本次安装失败或用户不满意，清理只能在**另一次明确授权**下进行。
- [ ] C8：确认执行者与时间；执行人承诺不在测试中途改 helper 参数、不加 `--no-wait`、不强杀进程。

---

## 10. 实施前与 Lead/helper 的接口核对项（技术门禁）

1. **CLI 契约（预检时从 `main.swift` 读到，最终以构建产物 `--help` 为准）**：`switchshelf-backend install --file <abs> [--wait 300] [--timeout 1800] [--journal <path>] [--chunk 262144] [--target sd] [--json]`，另有 `discover --wait <s> --json`；**无 `--name`**（文件名取 basename）；`--json` 始终输出 JSON。默认 journal 路径如上；退出码见 §4.6。执行前用 `--help` 复核。
2. **会话默认值（预检时源码）**：`InstallRequest` 默认 `sessionTimeoutSeconds=1800`、`maximumChunkSize=262_144`、`operationTimeoutMilliseconds=15,000`；CLI `--wait` 默认 300、`--timeout` 默认 1800、`--chunk` 默认 262144、`--target` 默认 `sd`。确认 `--timeout 1800` 会传入 `BackendSessionOptions.sessionTimeoutMilliseconds`，而不是退回该类型默认 120 s。
3. **命令预算（预检时源码已设置 50,000）**：`InstallRun` 已把 `BackendSessionOptions.maximumCommands` 设为 **50,000**（默认值 4,096 已不再使用；上限 100,000）。最坏情况若设备按 64 KiB 范围请求，834 MB 约 12,700 个命令，50,000 有足够余量。执行前记录该值并确认最终二进制包含它；若设备请求更细粒度，仍需按 §5 的超时中止处理。
4. **租约路径**：helper 必须使用 `DeviceLease.defaultURL`（`~/Library/Application Support/SwitchShelf/device-lease.lock`），测试环境不得设置 `SWITCHSHELF_DEVICE_LEASE_PATH`；app/probe/helper 三者互斥。
5. **失败不写设备**：确认 helper 在预检失败、lease busy、描述符不符、journal 失败时不打开设备；在传输失败/取消时只 `close` 一次、不自动重试、不重连。
6. **等待顺序**：默认等待模式（先 helper、后 Switch 按 Y）；确认 300 s 等待期间不打开设备、不抢 MTP；`--no-wait` 不使用。
7. **构建产物**：执行窗口内不 `swift build`/`swift test`（避免中途换二进制）；二进制/HEAD/`--help` 证据在阶段 0 前采集。
8. **证据边界**：helper 报告中的 `transferredAwaitingConfirmation` 与 journal `finished` 只能被写成“主机已完成字节交换、等待设备确认”，任何文档/UI/汇报都不得写成“安装成功”。

---

## 11. 预检事实附录（本次只读命令与结果摘要）

| 检查 | 命令 | 结果（2026-10-23 23:38–23:41 +08:00） |
|---|---|---|
| DB 候选 | `sqlite3 -readonly …`（见 §1.1） | `base` 最小项 = 鹅本体 834,297,609 B；`availability=online` |
| 文件类型/大小 | `stat`/`os.path`（见 §1.2） | 普通文件、非链接、`size=834297609`、mode 0700、SMB `dev=905969671` |
| 文件内容 | 未读取 | 仅 `file` 读签名：`PFS0, 7 files`；**未哈希、未复制** |
| USB | `ioreg` | 仅 `057e:201d`（DBI MTP，class 6/1/1，3 端点，`ptpcamerad` 独占）；**无 `057e:3000`** |
| App/进程 | `pgrep`/`lsof` | SwitchShelf PID 67018 运行；无 probe/其他 MTP 客户端 |
| 租约 | `lsof device-lease.lock` | 文件存在 0 B，**无持有者** |
| journal | `ls` App Support | `backend/` 与 `journal.json` 尚不存在 |
| 源网络 | `mount`/`route` | SMB `//jiazi@192.168.62.4/switch 游戏包`；本机 `en0` `192.168.62.6` |
| helper | `ls`/`git status` | 预检时开发中（`Package.swift` 未提交改动、`Sources/SwitchShelfBackendInstall/` 未跟踪、CLI 产物缺失）；23:45 复核 CLI/测试文件已出现但构建/测试未取证 → **仍按 §2.3 门禁** |
