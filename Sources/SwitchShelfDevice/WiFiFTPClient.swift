import Foundation

/// Read-only DBI FTP client for the documented SD file-access port.
/// It never opens USB, takes the device lease, or sends a write/install command.
public actor WiFiFTPClient {
    private let opener: any WiFiFTPChannelOpening
    private let limits: WiFiFTPLimits
    private var channel: (any WiFiFTPByteChannel)?
    private var current: UInt64 = 0
    private var busy = false
    private(set) var lastCommands: [String] = []
    private var snapshot = WiFiFTPSnapshot.notConnected

    public init() {
        self.opener = POSIXWiFiFTPOpener()
        self.limits = WiFiFTPLimits()
    }

    init(limits: WiFiFTPLimits) {
        self.opener = POSIXWiFiFTPOpener()
        self.limits = limits
    }

    init(opener: any WiFiFTPChannelOpening, limits: WiFiFTPLimits = WiFiFTPLimits()) {
        self.opener = opener
        self.limits = limits
    }

    public func connect(hostText: String, portText: String) async -> WiFiFTPSnapshot {
        switch WiFiFTPEndpointParser.parse(host: hostText, portText: portText) {
        case .rejected(let rejected):
            await cancelOpenChannel()
            snapshot = rejected
            lastCommands = []
            return rejected
        case .ready(let host, let port):
            return await connect(host: host, port: port)
        }
    }

    public func connect(host: String, port: UInt16) async -> WiFiFTPSnapshot {
        current &+= 1
        let token = current
        busy = true
        defer { busy = false }
        if let existing = channel {
            channel = nil
            await existing.close()
        }
        guard token == current else { return snapshot }
        let result = await WiFiFTPExchange.run(opener: opener, host: host, port: port, limits: limits) { opened in
            await self.hold(opened, token: token)
        }
        guard token == current, !result.superseded else { return snapshot }
        lastCommands = result.commands
        snapshot = result.snapshot
        if snapshot.phase != .connected, let opened = channel {
            channel = nil
            await opened.close()
        }
        return snapshot
    }

    public func disconnect() async -> WiFiFTPSnapshot {
        current &+= 1
        let opened = channel
        channel = nil
        var acknowledged = false
        if let opened {
            if !busy, let wrote = await WiFiFTPExchange.quit(opened) {
                lastCommands.append("QUIT")
                acknowledged = wrote
            }
            await opened.close()
        }
        let host = snapshot.host
        let port = snapshot.port
        snapshot = WiFiFTPSnapshot(
            phase: .disconnected,
            host: host,
            port: port,
            summary: "未连接。",
            nextStep: acknowledged
                ? "本机已发送 QUIT，并收到 221。若 Switch 画面仍停在 FTP，以画面为准。需要时再连接。不会自动重试，也不会打开 USB。"
                : "本机连接已关闭。Switch 端会话是否结束保持未知，请看 DBI 画面。需要时再连接。不会自动重试，也不会打开 USB。",
            greeting: .unknown,
            workingDirectory: .unknown,
            listingText: .unknown
        )
        return snapshot
    }

    private func hold(_ opened: any WiFiFTPByteChannel, token: UInt64) async -> Bool {
        guard token == current else {
            await opened.close()
            return false
        }
        channel = opened
        return true
    }

    private func cancelOpenChannel() async {
        current &+= 1
        if let opened = channel {
            channel = nil
            await opened.close()
        }
    }
}
