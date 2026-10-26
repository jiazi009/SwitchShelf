import SwiftUI
import SwitchShelfDevice

struct WiFiConnectView: View {
    @Bindable var model: AppModel

    private var phase: WiFiLinkPhase { model.wifi.phase }
    private var tone: StatusTone {
        switch phase {
        case .disconnected: .neutral
        case .connecting: .accent
        case .connected: .success
        case .failed: .danger
        case .unknown: .warning
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let notice = model.notice {
                        NoticeBanner(notice: notice) { model.perform($0) } onDismiss: { model.notice = nil }
                    }
                    statusCard
                    endpointCard
                    probeCard
                    instructionsCard
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(Theme.canvas)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PageHeading(title: "无线连接", subtitle: model.wifiSubtitle)
            BadgePill(text: "Wi-Fi", systemImage: "wifi", tone: .accent)
            Spacer()
            Button {
                Task { await model.disconnectWiFi() }
            } label: {
                Label("断开", systemImage: "wifi.slash")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.glass)
            .disabled(!model.isWiFiBusy && phase != .connected && phase != .connecting)
            .help("关闭本机 FTP 控制连接。不会向 Switch 上传或安装。")
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }

    private var statusCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(tone.soft)
                            .frame(width: 54, height: 54)
                        if phase == .connecting || model.isWiFiBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: phase.symbol)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(tone.color)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(phase.label)
                                .font(.system(size: 16, weight: .semibold))
                            BadgePill(text: "DBI FTP", systemImage: "externaldrive.connected.to.line.below", tone: tone)
                        }
                        Text(model.wifi.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                }
                nextStep
            }
        }
    }

    private var nextStep: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone.color)
                .padding(.top, 1)
            Text(model.wifi.nextStep)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var endpointCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "wifi")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                    Text("要连接的主机")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("默认端口 \(DBIWiFiDocumentedPorts.fileAccess)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    TextField("主机，例如 192.168.1.20", text: $model.wifiHost)
                        .textFieldStyle(.roundedBorder)
                        .disabled(fieldsLocked)
                        .accessibilityLabel("FTP 主机")
                    TextField("端口", text: $model.wifiPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 88)
                        .disabled(fieldsLocked)
                        .accessibilityLabel("FTP 端口，留空为 5000")
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await model.connectWiFi() }
                    } label: {
                        Label("连接并只读探测", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isWiFiBusy || phase == .connected || model.wifiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isDiscovering || model.isReadingInventory || model.isInstalling)
                    Text("只发送匿名登录、PWD、PASV 和 LIST。不上传，不安装，不打开 USB。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var probeCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("这次实际读到的内容")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("没有读到就保持未知")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                probeRow("问候", model.wifi.greeting)
                probeRow("工作目录", model.wifi.workingDirectory)
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIST 原文")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    switch model.wifi.listingText {
                    case .unknown:
                        Text("未知")
                            .font(.system(size: 12, weight: .medium))
                    case .observed(let text) where text.isEmpty:
                        Text("空文本")
                            .font(.system(size: 12, weight: .medium))
                    case .observed(let text):
                        ScrollView {
                            Text(text)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 160)
                    }
                    Text("这是 FTP 目录文本，不是已安装游戏。文件名没有经过包身份校验。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                probeRow("已安装游戏", WiFiObservation<String>.unknown)
                probeRow("包身份", WiFiObservation<String>.unknown)
            }
        }
    }

    private func probeRow(_ title: String, _ value: WiFiObservation<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(displayed(value))
                .font(.system(size: 12, weight: .medium, design: value == .unknown ? .default : .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func displayed(_ value: WiFiObservation<String>) -> String {
        switch value {
        case .unknown: "未知"
        case .observed(let text): text.isEmpty ? "空文本" : text
        }
    }

    private var instructionsCard: some View {
        SurfaceCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "book.pages")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.violet)
                    Text("使用 DBI 的 FTP，而不是 USB")
                        .font(.system(size: 13, weight: .semibold))
                }
                step(1, "在 Switch 上打开 FTP", "进入 DBI，选择 Run FTP server。本应用不能替你打开它，也不会扫描局域网。")
                step(2, "填写主机", "端口留空时使用文档中的 5000，也就是 SD 文件访问端口。6000 是安装端口，这里会直接拒绝，不会连接。")
                step(3, "只读探测", "连上之后只看问候、当前目录和一次 LIST 原文。看不到的内容保持未知，不会变成已安装游戏。")
                step(4, "和 USB 分开", "「我的 Switch」仍是 sphaira / DBI 的 USB MTP。无线会话连接期间不会同时做 USB 检测或安装测试。")
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.violet)
                    Text("sphaira 的网络菜单只说明如何打开 MTP，不是这条 Wi-Fi。HTTP 端口 \(DBIWiFiDocumentedPorts.httpConfig) 的可查询元数据尚未验证，所以这里不讲 HTTP。夹具测试不等于已经连上 Switch。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Theme.violet.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.violet)
                .frame(width: 20, height: 20)
                .background(Theme.violet.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fieldsLocked: Bool {
        model.isWiFiBusy || phase == .connected || phase == .connecting
    }
}
