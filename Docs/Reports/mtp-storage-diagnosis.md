# DBI 647 MTP 存储诊断 — 2026-10-23

当前结论：原生 MTP 握手、存储枚举和会话关闭成功，但设备提供的九个存储中没有 Installed games。用户已确认开启该项、完全退出重开 DBI、停在 MTP，并在后续按提示拔插 USB 重连。重连后的存储列表没有改变。用户随后确认 DBI 本机“浏览已安装的应用程序”能看到正常游戏列表。

这证明设备上存在可由 DBI 本机读取的游戏列表，不能把探测的零条记录解释为未安装游戏；也不能把当前问题归因于用户未重启、未插好线或一个已观察到的中文 Installed games 名称未匹配。实际加载的配置、该中文构建的 MTP 行为及版本兼容仍未确定。

## 真实设备检查

所有检查顺序执行，均使用原生 ImageCaptureCore broker，显式限时 30 秒；进程正常退出。未并发启动客户端，未杀系统相机／MTP 进程，未切换全局设置。仅第一项尝试 Installed games 清单；其余两项是随后新增的存储名称诊断，不遍历内容对象。

| 时间（Asia/Shanghai） | 检查 | 耗时 | 返回 |
|---|---|---|---|
| 21:51:56 | `inventory --transport native --timeout 30 --json` | 2.213 秒 | exit 2，`partial`，`isComplete=false`，0 records；未匹配到 Installed games，未进入其对象遍历 |
| 21:58:34 | `storages --transport native --timeout 30 --json` | 2.245 秒 | exit 2，`partial`；仅获得九项存储描述，未读取内容对象 |
| 22:00:36 | 用户拔插 USB 并确认重回 MTP 后，单次 `storages` | 2.179 秒 | 相同九项存储；诊断模式故意不构成完整已安装清单 |

实际存储描述及本次会话中的句柄如下。句柄不构成持久设备身份。

| ID | 设备报告的名称 |
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

`5: SD Card install`／`6: NAND install` 不能作为 Installed games 清单入口；未枚举这些安装入口或存档。没有获得 Installed games 的对象名、层级、Title ID、版本或类型证据，未新增任何猜测的本地化识别规则。

原始 JSON、退出状态和耗时保存于忽略目录，子目录权限 0700、文件 0600：

- `output/diagnostics/inventory-647-20261023T135154Z/`
- `output/diagnostics/storages-647-20261023T135832Z/`
- `output/diagnostics/storages-after-reconnect-647-20261023T140033Z/`

没有修改 DBI 配置、设备对象、存档或源游戏包，没有传输、安装或完整哈希大文件。CLI 结果未注入正在运行的 App，不能声称 App 的实机清单显示也已验收。

## 代码与验证

代码提交 `c9fe0c4`，分支 `codex/source-access-recovery`，未合并主分支。

- `InventoryReader.swift`：未识别入口时保留实际存储描述；名称转义、数量及长度有界。增加仅存储诊断分支，即使存在已知 Installed games 名称，也不调用内容对象枚举，始终保持 `isComplete=false`、零 records。
- `DeviceService.swift`：新增 `readStorageDiagnostics()`，保留既有 `readInventory()` 接口，通过同一个会话 gate。
- `NativePTPTransport.swift`：将诊断选项传入读取器，沿用正常打开／关闭与失败释放路径。
- `SwitchShelfProbe/main.swift`：增加显式 `storages` 模式，沿用独立 worker 和硬超时；帮助说明诊断成功时 exit 2 表示未读取安装清单。
- `DeviceTests.swift`：增加有界／转义诊断及识别到目标也不遍历的回归；强化 SD 中文名称不构成安装证据的断言。

`swift test`：**86 项通过**（库 30、领域 8、设备 48）。本轮 NAS 只读元数据测试仍为 16 款／48 个包／0 问题，约 0.235 秒。`swift build`、`python3 scripts/build-app.py`、严格签名验证通过；bundled probe 帮助与无效 timeout 用法检查未访问 USB。新 `storages` CLI 的真实执行结果见上表。签名仍为本机 ad-hoc，未公证／发行。

未修改 `Package.swift`、共享领域模型、其他工作树或未跟踪 `.pi/`。本会话没有注入 worker Dispatch，Orca 检查无待处理消息；未恢复旧 Run 或已暂停 Goal，未启动任何 agent。

## 配置与版本证据的范围

- 官方说明配置应与 `DBI.nro` 位于同一目录，并提供 DBI 内部配置管理器。[DBI 配置说明](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/README.md#dbiconfig)
- 本地既有 `dbi.config.original` 与 `.proposed` 只是以前的快照／提案：前者 Installed games=false，后者=true；两者 SD Card=false、Album=true。本轮实际 catalog 则包含标准 SD Card、没有 Album。不能据旧快照断言设备当前加载了哪份文件；本轮未下载或修改当前设备配置。
- 用户报告 647-zhcn／19.0.1e；官方 710 的发布记录提到开始准备支持 FW 19.0.0。这个时间线只提示需要核对构建兼容，不能证明此次缺入口由版本导致，尤其用户已确认 DBI 本机列表正常。[710 官方发布记录](https://github.com/rashevskyv/dbi/releases/tag/710ru)
- 已向用户询问“开启”是在 DBI 内部配置页面确认，还是仅检查／修改过 SD 上的文件；尚未取得该区分。不会再要求重复确认已经完成的 DBI 重启与 USB 重连。

## 替代连接方式与下一步

用户询问 MTP 是否适合及其他连接方式。当前 USB/MTP 元数据链路已成功，缺失的是 DBI 暴露的 Installed games 入口。

| 方式 | 已有官方证据 | 对 SwitchShelf 的意义 |
|---|---|---|
| MTP | 虚拟 Installed games 清单、独立本体／更新／DLC 对象等说明 | 保留为可选只读清单通道；当前设备清单未通过 |
| USB Backend | 官方主机脚本实现文件列表、按区间读取待安装文件、退出命令 | 推荐后续安装主通道；没有在该脚本中发现目标设备已安装清单查询 |
| FTP | 官方说明 SD 文件访问及独立安装端口 | 可做网络文件／安装适配；不能直接等同于系统已安装清单 |
| HTTP | 官方文档描述网络来源安装；配置也暴露 HTTP server 项 | 可做网络补充；647 的可查询元数据接口尚未验证 |

来源：[MTP](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/README.md#run-mtp-responder)、[USB Backend 使用](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/README.md#install-title-from-dbibackend)、[官方主机脚本](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/dbibackend)、[网络来源](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/README.md#home-server)、[HTTP 配置](https://github.com/rashevskyv/dbi/blob/22090afc64cc7b5d645a99bf3d4d8625a67b766e/dbi.config)。本轮仅阅读资料，未运行官方传输脚本、启用网络服务或更换 DBI。浏览研究已结束并关闭 ego TaskSpace 6；工具提示可更新，未执行升级。

后续安装可采用 USB Backend，与清单读取保持独立。现在不执行安装：尚需 Backend 实现、受审查的测试文件／目标及结果确认语义。当前安装状态继续保持未知，原本计划执行禁用的边界不变。若继续排查清单，先核对 DBI 内部配置值及实际启动的 NRO／配置位置；所有探测已退出，可由用户查看 DBI 本机页面。用户可能已退出 MTP 查看游戏列表，下次访问设备前要取得新的 MTP 就绪信息。
