import SwiftUI
import SwitchShelfDevice

struct MTPInstallConfirmation: View {
    let request: SphairaInstallRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var authorizedFile = false
    @State private var confirmedDevice = false
    @State private var exclusiveClient = false
    @State private var understandsRisk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("确认一次 sphaira 安装测试", systemImage: "exclamationmark.triangle")
                .font(.title2.bold())
            Text("这一步会真实读取下面的游戏包并向 Switch 发送数据。此通道尚未经实机安装验收；不是只读清单测试。")
                .foregroundStyle(.secondary)
            GroupBox("仅发送这个文件") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.name).font(.headline)
                    Text(request.sourceURL.path).font(.caption).textSelection(.enabled)
                    Text("大小：\(formatByteCount(Int64(request.byteCount)))（\(request.byteCount) 字节）")
                    Text("计划意向：\(request.intendedTarget == "sd" ? "SD 卡" : "机身存储")；必须在 sphaira 端自行选择，应用不能设置目标。")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            Toggle("我有权使用并明确同意安装上述这个文件", isOn: $authorizedFile)
            Toggle("我已在 sphaira 进入 MTP Install，核对目标存储和安装设置", isOn: $confirmedDevice)
            Toggle("我已退出 OpenMTP、预览等其他 MTP 客户端", isOn: $exclusiveClient)
            Toggle("我了解发送完成不等于安装成功；失败后先检查设备，不自动重试", isOn: $understandsRisk)
            Text("不会删除设备对象、修改存档、格式化或自动恢复。中断不保证设备端回滚。若使用较旧 sphaira，存储名或能力不匹配会拒绝发送。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认并发送这一个文件", action: onConfirm)
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(!authorizedFile || !confirmedDevice || !exclusiveClient || !understandsRisk)
            }
        }
        .toggleStyle(.checkbox)
        .padding(24)
        .frame(width: 640)
    }
}
