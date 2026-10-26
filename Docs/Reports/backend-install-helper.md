# DBI Backend 安装 helper（switchshelf-backend）— 2026-10-23

本轮实现生产可用的 Backend 主机 helper，用于用户授权的“安装一个真实游戏”实机测试。实现复用既定 Backend 模块，未修改 App 的安装按钮状态，也未进行一次真实 USB 传输。

## 组成

| 组件 | 路径 | 作用 |
|---|---|---|
| 核心库 | `Sources/SwitchShelfBackendInstall/` | 预检、允许列表范围读取、共享租约、显式打开、协议会话、journal、报告 |
| 可执行目标 | `Sources/SwitchShelfBackendCLI/main.swift` | `switchshelf-backend discover|install`，JSON 输出与退出码 |
| 测试 | `Tests/SwitchShelfBackendInstallTests/` | 6 项 fake transport/provider 测试，不依赖硬件 |

`Package.swift` 新增 `SwitchShelfBackendInstall`（库）、`switchshelf-backend`（可执行 product，target `SwitchShelfBackendCLI`）与测试 target。

## 数据流（install）

1. 等待 IOKit 出现唯一 `057e:3000` DBI Backend 描述符（只读枚举，不打开设备）。
2. 本地预检：绝对路径、普通文件、大于 0、扩展名受支持、basename 可作为协议文件名、大小与元数据一致。
3. `AllowlistedBackendFileReader`：逐层 `O_NOFOLLOW`、绑定 id/URL/size、每次读取前后核对 inode/mtime/ctime。
4. `BackendTransferJournal`：写 `~/Library/Application Support/SwitchShelf/backend/journal.json`；每个成功数据块后记录保守快照；最终 `finished` 仍只表示主机侧交换。
5. `SharedDeviceLease`：复用 `~/Library/Application Support/SwitchShelf/device-lease.lock`，与 MTP probe 互斥。
6. `BackendUSBTransport.open(lease:)` → `BackendSession.run`：只服务本次 offer 的文件；设备 EXIT 后结束并只关闭一次。
7. 报告 JSON：`outcome`、字节覆盖、`peerRequestedExit`、attempt id、journal 路径/状态、notes。

## 命令

```sh
swift build -c release --product switchshelf-backend

# 只读检查 Backend 描述符是否出现（不打开设备）
.build/release/switchshelf-backend discover --wait 30 --json

# 用户授权的一次安装尝试（切换 DBI 模式后再运行）
.build/release/switchshelf-backend install \
  --file "/Volumes/switch 游戏包/.../Untitled Goose Game [....][v0].nsp" \
  --wait 300 --timeout 1800 --journal "$HOME/Library/Application Support/SwitchShelf/backend/journal.json" --json
```

Switch 侧：DBI 主菜单 → **Install title from DBIbackend**（Y）→ 选择主机列出的文件 → 选择 Target（SD）→ Start install。目标选择与最终安装结果都由设备端决定/显示，主机协议不携带目标设置命令。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 主机完整覆盖 + 设备请求 EXIT；**不证明已安装** |
| 1 | 失败（预检/协议/传输等），设备结果未知 |
| 2 | 不完整传输（超时/断连/EXIT 时覆盖不足） |
| 3 | 未发现 `057e:3000` 设备 |
| 4 | 设备被其他进程占用（租约 busy） |
| 5 | journal 不可用/最终记录失败 |
| 64 | 用法错误 |
| 124 | 硬超时（会话预算 + 120 秒） |
| 130 | 取消 |

## 安全边界

- 只读源文件：不移动、重命名、删除、修改源包；不整包读入内存（按请求范围读取）。
- 不删除设备对象、不写存档、不格式化、不改设备配置；安装目标由用户在设备上确认。
- 无自动重试：断连/超时后设备安装结果保持未知；不会自动重连。
- journal 是主机侧证据：`finished`/EXIT 都不等于安装成功。
- App 内安装按钮仍为禁用状态；本 helper 是独立受审查 CLI，不改变 App 行为。

## 验证

- `swift build` 通过；`swift test --filter BackendInstall` 6 项通过。
- `switchshelf-backend discover --json` 在仅 MTP（`057e:201d`）连接时返回 `found:false`、退出码 3，未打开设备。
- 未进行真实 Backend 传输；设备端 ACK/描述符行为仍是实机待验证项。

## 证据限制

真实 DBI 647-zhcn 的 Backend 描述符（`057e:3000`、class `0xff`、bulk 端点 `0x01/0x81`）、ACK 长度字段、分块节奏与 EXIT 时机均取自固定版本官方脚本与仓库既有分析，尚无本机实机证据；安装成功与否只能由设备端显示和用户确认。详见 `backend-install-conformance.md` 与 `backend-install-field-test.md`。
