import SwiftUI
import SwitchShelfDevice

struct MTPInstallConfirmation: View {
    let review: SphairaBatchReview
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var authorizedFiles = false
    @State private var confirmedDevice = false
    @State private var exclusiveClient = false
    @State private var understandsRisk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView { confirmationDetails.padding(24) }
            Divider()
            HStack {
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("确认并发送队列", action: onConfirm)
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(!authorizedFiles || !confirmedDevice || !exclusiveClient || !understandsRisk)
            }.padding(20)
        }
        .toggleStyle(.checkbox)
        .frame(width: 640, height: 600)
    }

    private var confirmationDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("确认 sphaira 安装队列", systemImage: "exclamationmark.triangle").font(.title2.bold())
            Text("将依次读取并发送以下游戏包。传输完成不等于安装成功，批量发送尚需实机验收。")
                .foregroundStyle(.secondary)
            GroupBox("发送顺序 · \(review.items.count) 个文件") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(review.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(item.gameTitle) · \(item.request.name)").font(.headline)
                            Text(item.request.sourceURL.path).font(.caption).textSelection(.enabled)
                            Text(formatByteCount(Int64(item.request.byteCount))).font(.caption)
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    Text("总大小：\(formatByteCount(Int64(clamping: review.totalBytes)))")
                    if let target = review.items.first?.request.intendedTarget {
                        Text("计划目标：\(target == "sd" ? "SD 卡" : "机身存储")。必须在 sphaira 端选择相同位置，应用不能设置目标。")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Toggle("我有权使用并同意发送上述所有文件", isOn: $authorizedFiles)
            Toggle("我已在 sphaira 进入 MTP Install，核对目标存储和安装设置", isOn: $confirmedDevice)
            Toggle("我已退出 OpenMTP、预览等其他 MTP 客户端", isOn: $exclusiveClient)
            Toggle("我了解发送完成不等于安装成功；失败后先检查设备，不自动重试", isOn: $understandsRisk)
            Text("中断不保证设备端回滚。发送失败或设备状态不明时队列会停止。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
