# 无线 FTP 连接 — 2026-10-26

这条分支在现有 USB MTP 之外加了一条用户可操作的无线连接。没有替换 sphaira / DBI 的 USB 清单，也没有改写单文件安装测试。本轮没有连接用户的 Switch，没有打开 USB，没有占用 device lease，没有扫描或复制 `/Volumes/switch 游戏包`。

## 协议选择

依据仓库已有记录和固定的上游提交 `22090afc64cc7b5d645a99bf3d4d8625a67b766e`，不是一次实机握手。

| 选项 | 文档怎么说 | 本分支 |
|---|---|---|
| DBI FTP 5000 | README「Run FTP server」：通过端口 5000 访问 SD 文件；同提交的 `dbi.config` 里 `[FTP] Port=5000` | 采用。控制连接加上一次当前目录 `LIST` |
| DBI FTP 6000 | 同一句 README：通过端口 6000 安装文件 | 拒绝。解析阶段就返回失败，不创建套接字 |
| DBI HTTP 1234 | `dbi.config` 的 `[HTTP] Port=1234`。诊断记录写明 647 的可查询元数据接口尚未验证 | 不实现。若用户把端口指到返回 HTTP 的服务，状态是未知 |
| sphaira 网络菜单 | 设备页已有说明：用来打开 MTP 和 Games | 仍只属于 USB 页，不是这条 Wi-Fi |

匿名账号没有写在这份 README 里。客户端只尝试一次 `USER anonymous` / `PASS anonymous`。530 或无法识别的登录应答会停下来，不猜其他账号。`LIST` 的格式也没有被文档规定，所以界面保留原文，不拆成文件类型、大小或 Title ID。

被动数据地址必须和对端地址一致。不一致就不开数据连接，目录保持未知。配置里的被动端口范围可以是自动，因此客户端不把数据端口限定在 40000–40100。

已连接只表示 FTP 控制会话进入了可读取状态。问候、工作目录、`LIST` 原文各自独立：没读到就是未知。空的 `LIST` 文本不是「没有已安装游戏」。文件名不是已验证的包身份。

## 改动

- `Sources/SwitchShelfDevice/WiFiFTPProtocol.swift`：端口、状态、应答解析、只读命令序列
- `Sources/SwitchShelfDevice/WiFiFTPSocket.swift`：本机 TCP。不经过 ImageCaptureCore、libusb 或 device lease
- `Sources/SwitchShelfDevice/WiFiFTPClient.swift`：连接与断开。允许的命令只有 `USER anonymous`、`PASS anonymous`、`PWD`、`PASV`、`LIST`、`QUIT`
- `Sources/SwitchShelfApp/WiFiConnectView.swift`：独立的「无线连接」页
- `Sources/SwitchShelfApp/AppTypes.swift`、`SidebarView.swift`、`RootView.swift`、`SwitchShelfApp.swift`、`AppModel.swift`：侧边栏入口和会话状态
- `Sources/SwitchShelfApp/DeviceView.swift`、`QueueView.swift`：USB 页标明 USB；无线会话处于正在连接或已连接时，跳过 USB 检测、清单读取和安装测试
- `Tests/SwitchShelfDeviceTests/WiFiFTPTests.swift`：夹具和回环假服务
- 未改 `Package.swift`，未改共享领域模型

USB 在无线会话空闲时的检测、清单和安装测试路径没有改写。并发限制只在无线会话正在连接或已连接时生效。

## 测试

命令：

```sh
swift test --filter WiFiFTP --skip RealNASScanTests
swift test --skip RealNASScanTests
```

结果：Wi-Fi 过滤为 4 个套件、24 项通过。全量（跳过 `RealNASScanTests`）通过：Swift Testing 230 项（库 42、领域 12、设备 136、Backend 34、BackendInstall 6）以及 Backend XCTest 11 项。设备 136 项里包含这 24 项新测试，原有 USB 清单和安装夹具测试没有失败。

覆盖的是本机行为：成功对话、匿名登录被拒绝、TCP 拒绝、超时、无法识别的横幅、HTTP 响应、被动地址不一致、空 `LIST`、安装端口不建连。回环服务器跑在 127.0.0.1，不是 Switch。

## 尚未在真机上验证

- 没有连过用户的 Switch，不能说 Wi-Fi 已接通，也不能说读到了 SD 或已安装清单
- DBI 是否接受匿名登录、`LIST` 的真实格式、被动端口和工作目录，都还没有这份设备的证据
- HTTP 1234 的元数据接口仍然未验证，本实现不去查询它
- 未做实机窗口验收。应用目标已随测试编译通过，但没有用实机界面确认液态玻璃的最终观感
