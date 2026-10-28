# libusb 与 ImageCaptureCore 只读连接对比 — 2026-10-27

## 参考与范围

按用户要求，对比现有 ImageCaptureCore 与 libusb，不评估 libmtp。OpenMTP 的公开 [Kalam 构建说明](https://github.com/ganeshrvel/openmtp/blob/master/ffi/kalam/native/README.md) 和 [go.mod](https://github.com/ganeshrvel/openmtp/blob/master/ffi/kalam/native/go.mod) 显示其使用 go-mtpfs / go-mtpx 和 libusb；该参考用于路线选择，并未复制 OpenMTP 源码。这里复用本项目已有 libusb 设备打开与数据通道，不引入 OpenMTP 的完整文件管理能力。其已知的 macOS USB 接口争用问题见 [OpenMTP PR #483](https://github.com/ganeshrvel/openmtp/pull/483)；本实现不停止系统服务、不 detach、不 reset。

## 实现

- 新增只读 `LibUSBInventoryTransport`：单会话只发送 OpenSession、CloseSession、GetStorageIDs、GetStorageInfo、GetObjectHandles 和 GetObjectInfo；严格校验响应事务号和长度，错误后停止发出后续请求，释放底层接口。沿用 `InventoryReader` 的 Games/Installed games 限定、资源预算和证据规则。
- `switchshelf-probe` 支持显式 `--transport libusb`；现有子进程隔离、同机 DeviceLease、超时和退出验证继续适用。`--transport native` 不变。
- 开发分支的“我的 Switch”可在两种清单读取方式之间手动切换。切换使旧会话清单变为历史记录并重新读取；选择只保留在本次应用运行中，启动默认系统连接。既有队列安装流程和实现不变。
- USB 对象和数据只是只读元数据，未调用 GetObject、安装、删除或格式化命令；无自动路线回退。设备清单的完整性不证明包身份或安装结果。

## 本次真实设备只读结果

用户确认 Switch 已进入 sphaira MTP 且其他 MTP 客户端退出。通过 IOKit 发现一个 `057e:201d` 候选后，先顺序运行 libusb 的 storages、inventory，再运行 native inventory；各进程均已结束，未并发连接。约 2026-10-27 22:54（上海时间）。

| 路线 | 只读清单结果 | 观察到的内容 |
|---|---|---|
| libusb | `ok`，完整，退出码 0 | 9 个存储、8 个游戏目录、30 个元数据对象、22 条记录、无问题 |
| ImageCaptureCore | `ok`，完整，退出码 0 | 9 个存储、8 个游戏目录、30 个元数据对象、22 条记录、无问题 |

两次存储名称顺序相同；以 Title ID、内容种类、版本、名称和对象路径比较，22 条记录一致。独立的 libusb `storages` 诊断返回退出码 2 / partial 是设计语义：只读取存储名称，不声称完整清单。未读取或发送游戏包，也未修改设备内容。

## 限制

以上是一次设备、一次环境下的顺序对比，不保证其他设备、插拔或连续重连的行为。libusb 可能因系统进程或其他客户端持有接口而无法打开；不会自行抢占。由于探针从命令行启动、签名和授权上下文不同于 GUI，本次不能判断应用首次连接的 macOS 授权弹窗是否消失。没有重置系统隐私权限，也没有以失去既有授权的状态测试。若发生超时或接口释放无法确认，必须保留未知状态并避免并发重试。

## 自动化和界面验证

首次离线套件通过后，会话因额度限制中断，代码尚未提交。续接核对了 `/private/tmp/switchshelf-mtp-work/{libusb,native}-inventory.json`，确认两个已保存的实机结果均为完整清单、22 条记录与存储证据一致；这不是再次连接设备的结果。

续接补强：StorageIDs、StorageInfo、ObjectInfo 按各自协议预算提前拒绝超大报文；数据集解析失败也使会话失效，不再发出后续元数据或 CloseSession 命令，但仍释放 USB。新增夹具覆盖 100,000 句柄的跨 USB 读取、无数据成功响应、错误操作/事务号/容器类型、空读取、忙响应、取消时释放，以及畸形数据集的停止行为。隔离进程还覆盖路线传递、不匹配和退出未确认时跨路线禁止重试。所有这些测试不打开 USB、不读取真实 NAS。

最终验证：

- `swift test --skip RealNASScanTests`：Swift Testing 274 项、XCTest 11 项全部通过；其中 libusb/隔离探针针对性测试 19 项通过。
- `python3 scripts/build-app.py`：release 应用与探针构建、libusb 运行库及许可证打包完成，`codesign --verify --deep --strict build/SwitchShelf.app` 通过。
- `clang -fsyntax-only -std=c11 -Wall -Wextra -Werror -DSS_VERIFY_SPHAIRA_USB_ABI -I Sources/CDBIBridge/include -I /opt/homebrew/include/libusb-1.0 Sources/CDBIBridge/sphaira_usb.c`：严格 C/官方 libusb 描述符 ABI 校验通过。
- `scripts/verify-ui-layout.sh`：用实际视图和隔离合成数据生成 24 个布局；检查了 960×640 深浅色设备页，连接选择器可见、无截断。离屏渲染不等同于真实窗口或首次权限验收。
- 本次续接未启动生产应用、未重新连接物理 USB、未读取 NAS 游戏包或发送安装文件；原正式应用未替换。

## 独立测试版使用与授权弹窗验证

分支：`codex/mtp-transport-comparison`。独立应用：本工作树 `build/SwitchShelf.app`；不会替换 `/Users/jiazi/Desktop/SwitchShelf/build/SwitchShelf.app`。两个包名称相同，使用完整路径区分，勿同时运行。

1. 正常退出现有 SwitchShelf、OpenMTP 和其他 MTP 客户端；确保没有安装正在执行。
2. **先断开 Switch**，再打开本工作树的应用，在“我的 Switch”中选择 **libusb 直连**。这样可以避免默认的系统路线在选择之前自动读取。此选择仅本次运行有效。
3. 将 Switch 保持在 sphaira MTP 页面后连接 USB，等待自动读取；也可主动点读取。只验证连接、Games 清单和系统提示，不点安装发送。
4. 记录是否出现权限提示、清单完整性、游戏目录数/记录数和错误；如需对比系统路线，在当前读取结束后手动切换。不要并发运行探针。

已授权的系统环境中“不弹窗”不能证明首次请求也不弹窗。本次未重置隐私权限、未停止系统服务，亦未声明绕过 macOS 安全保护。NAS 文件访问仍可能独立请求授权；本组件不改变该行为。
