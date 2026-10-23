# 接手推进与来源访问恢复 — 2026-10-23

第一阶段仍为部分验收。实际 App 的 NAS 扫描／持久化本轮成功；实时窗口交互和 DBI 647 已安装清单仍待现场条件，不把这些项目记为通过。

## 修订

分支：`codex/source-access-recovery`，基于 `main` 的交接提交 `5ea444b`。代码提交：`0b154a5`（`fix(library): refresh source access when reselecting existing folders`）。未合并其他分支，未修改 `Package.swift`、共享领域模型或其他工作树。

- `Sources/SwitchShelfApp/AppModel.swift`：修复在“添加文件夹”中选择已有来源时直接返回的问题。现在先更新来源的访问书签，再持久化和重扫；沿用原来源 ID、名称与缓存，已有安全作用域访问在取得新访问后平衡释放。书签创建失败时保留已有书签并提示。
- `Sources/SwitchShelfLibrary/LibraryScanner.swift`：后台解析已有书签时加 `.withoutUI`，与 App 的启动恢复策略一致；显式目录选择仍由 `NSOpenPanel` 完成。这不保证 SMB 系统调用有超时，也不是此前卡住原因已查明的证据。

## 检查与实际证据

- `swift test`：**84 项通过**（库 30、领域 8、设备 46）。本轮 NAS 只读元数据扫描耗时 0.343 秒，16 款归组游戏、48 个包、92,313,880,284 字节元数据总量、0 条扫描问题。没有读取完整包体、复制或完整哈希源文件。
- `swift build`、`python3 scripts/build-app.py`、`codesign --verify --deep --strict --verbose=2 build/SwitchShelf.app`：通过。签名仍为本机 ad-hoc，非公证／发行。
- 通过 `open build/SwitchShelf.app` 启动新构建，确认该路径下的实际 App 进程运行。启动前 App 的 SQLite 为 0 款／0 包；启动后只读查询 `~/Library/Application Support/SwitchShelf/library.sqlite` 得到 **16 款／48 包／0 条扫描问题**，`scannedAt` 为 **2026-10-23 21:40:15（Asia/Shanghai）**。这支持实际 App 扫描与持久化成功，不等于窗口呈现已验证。初始来源仍未保存书签；本轮没有通过目录选择对话框实际验证重新授权路径。
- `orca computer get-app-state --app local.switchshelf.app --restore-window --json` 报 `permission_denied`。按提示查询 Accessibility 并打开授权设置后，查询显示 Accessibility／Screenshots 均为 `granted`，重试仍报相同错误。不能声称搜索、列表、计划编辑、亮暗、960×640 或玻璃材质已现场通过。此前 NAS 卡住本轮未复现，原因仍未知。

## 协调与剩余工作

本会话没有注入 worker Dispatch；`orca orchestration run-current` 返回 `null`，本会话检查及原协调者收件箱检查均无待处理消息。未接管旧 Run、未启动任何 agent、未恢复交接中已暂停的 Goal。状态通过本报告和 Orca 工作树备注记录，不能伪报旧 worker 生命周期事件。

1. 用户解锁 Mac，检查当前运行的 SwitchShelf；处理可能出现的文件访问／Orca Computer Use 权限提示。先核对实际窗口是否为 16 款游戏，再验收搜索、列表、队列及布局。需要重新选择来源时，在“添加文件夹”中选择 `/Volumes/switch 游戏包`，不要先移除缓存来源。
2. 用户在 Switch 上确认 `4: Installed games=true` 后完全退出并重新打开 DBI，停留在“运行 MTP 传输程序”，关闭其他 MTP／USB 客户端，再明确通知就绪。此前确认仍未收到，因此本轮**没有执行真实设备 inventory 或其他设备探测**。
3. 条件就绪后再运行一次独占、限时、只读的清单 probe，记录 DBI 647 的实际 storage／对象命名与完整性，再决定兼容修订。安装、传输、删除和设备写入仍未授权。

当前 App 留在运行状态供现场检查；未跟踪 `.pi/` 与用户已有数据未被删除。
