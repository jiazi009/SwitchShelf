# SwitchShelf / OpenMTP MTP 连接对照 — 2026-10-25

用户确认已在 Switch 上开启 MTP，并要求现在测试连接。本轮先运行 SwitchShelf 的限时原生探测，再运行官方 OpenMTP 临时副本；客户端顺序执行。

## 结果

| 项目 | 实际结果 | 证据边界 |
|---|---|---|
| SwitchShelf USB discovery | 18:16:02（Asia/Shanghai），0.018 秒，exit 0；仅一台 `057e:201d` MTP 候选设备 | 描述符发现本身不证明 MTP 会话可用 |
| SwitchShelf native storages | 18:16:04，2.250 秒，exit 2；成功打开、枚举九项存储并结束会话 | 存储诊断模式故意返回 `partial` / `isComplete=false`，不遍历内容对象；exit 2 不是本次连接失败 |
| OpenMTP 3.3.0 Kalam | 首次启动显示 `An error occured while setting up the Phone` | 未获得存储列表；没有低层错误码，不能确定失败原因 |
| OpenMTP 3.3.0 Legacy | 界面切换后单次刷新，未获得存储列表；退出 GUI 后直接运行自带 `mtp-cli storage-list`，启动时报 `OSError [Errno 86] Bad CPU type in executable` | `file` 确认该 CLI 为 `x86_64`；这是本机执行条件限制，不构成设备返回空清单的证据 |

原生通道返回的存储描述与 2026-10-23 的诊断一致：

| 会话内 ID | 存储描述 |
|---|---|
| 65537 | `1: SD Card` |
| 65541 | `5: SD Card install` |
| 65542 | `6: NAND install` |
| 65543 | `7: Saves` |
| 65792 | `1: SD内存卡` |
| 65793 | `金手指＆Mod` |
| 65794 | `相册工具` |
| 65795 | `主题` |
| 65796 | `JKSV存档备份` |

仍没有 `Installed games`。这证明当前原生通道能够通信，但本轮没有得到已安装内容清单，不能推断设备没有游戏。OpenMTP 本轮也没有提供可用于比较的存储列表，因此仍无法区分 ImageCaptureCore 通道差异与 DBI 入口暴露问题。

## 测试副本和证据

- 使用现有 `.build/debug/switchshelf-probe`：`discover --transport native --timeout 10 --json`，随后单次 `storages --transport native --timeout 30 --json`。
- OpenMTP 下载自官方 [v3.3.0 发布页](https://github.com/ganeshrvel/openmtp/releases/tag/v3.3.0)，资源为 `openmtp-3.3.0-mac-arm64.zip`。
- ZIP SHA-256 与发布资源摘要一致：`71c8ea9a7efa0a39bf443e56f79a88c2b2068d90d614761dc27584816d1f64ee`；`codesign --verify --deep --strict` 通过。
- 临时应用位于 `/private/tmp/switchshelf-openmtp-20261025/OpenMTP.app`，未复制到 Applications。其 `arm64/kalam.dylib` 为 arm64，`mtp-cli` 为 x86_64；未安装 Rosetta。
- OpenMTP GUI 观察先使用 Orca；其坐标操作因焦点识别失败未执行，随后通过可用的 Cua 原生界面通道完成语义操作。未调整系统权限或全局设置。
- 原始 JSON、耗时、退出状态、OpenMTP 结果摘要及 Kalam 初始错误截图保存在被 Git 忽略的 `output/diagnostics/mtp-connection-20261025T181602+0800/`；目录权限 0700，证据文件 0600。

## 范围和限制

没有发起文件传输、安装、创建或删除设备对象、存档操作或格式化；没有读取 NAS 游戏源文件。原生探测仅查询 USB 描述符和 MTP 存储元数据。OpenMTP 的初始化内部是否执行过 USB reset 没有协议跟踪证据，保持未知。

未重复运行原生清单遍历，未为得到成功结果而循环刷新、重启 DBI 或要求再次拔插。没有修改应用实现，也没有运行硬件无关单元测试；本轮验证是实际连接诊断。结束时进程检查确认 OpenMTP、mtp-cli、switchshelf-probe 和 switchshelf-backend 均未运行。

后续若继续调查 OpenMTP，应先取得 Kalam 的具体初始化错误；若调查已安装清单，应核对 DBI 实际运行构建与内部配置。当前安装状态继续保持未知。
