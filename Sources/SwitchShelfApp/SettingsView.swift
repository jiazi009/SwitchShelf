import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.refreshOnLaunch) private var refreshOnLaunch = false
    @State private var errorMessage: String?

    private var appDataDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwitchShelf", isDirectory: true)
    }

    var body: some View {
        Form {
            Section("扫描") {
                Toggle("启动时刷新已缓存来源", isOn: $refreshOnLaunch)
                Text("缓存为空时始终会执行首次扫描。已缓存时关闭此项可避免每次启动都访问 SMB 来源，仍可用 ⌘R 手动刷新。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("本地数据") {
                LabeledContent("位置") {
                    Text(appDataDirectory.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("打开应用数据目录") {
                        openDataDirectory()
                    }
                    Button("在访达中显示缓存") {
                        revealCache()
                    }
                }
                Text("缓存与安装计划只存放在本机。游戏与设备内容不会被上传，来源文件夹始终只读。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("关于") {
                LabeledContent("SwitchShelf", value: version)
                LabeledContent("游戏库", value: "本地文件 · 只读扫描")
                LabeledContent("设备", value: "USB 清单 · 安装队列")
                Text("安装队列通过 sphaira 依次发送文件。点击开始安装后立即发送。发送完成不等于安装成功，设备端安装结果仍需自行确认。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 440)
        .alert("无法打开本地数据", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "开发版本"
    }

    private func openDataDirectory() {
        do {
            try FileManager.default.createDirectory(at: appDataDirectory, withIntermediateDirectories: true)
            if !NSWorkspace.shared.open(appDataDirectory) {
                errorMessage = "访达未能打开该目录。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revealCache() {
        let url = appDataDirectory.appendingPathComponent("library.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "尚未生成缓存数据库。完成一次扫描后再试。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
