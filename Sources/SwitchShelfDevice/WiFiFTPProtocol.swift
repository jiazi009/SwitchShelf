import Foundation

/// Ports recorded from rashevskyv/dbi `22090afc64cc7b5d645a99bf3d4d8625a67b766e`.
/// The README's "Run FTP server" entry says port 5000 accesses SD files and port 6000 installs files.
/// `dbi.config` at that commit sets `[FTP] Port=5000` and `[HTTP] Port=1234`.
/// None of these values means a session to this user's Switch has been observed.
public enum DBIWiFiDocumentedPorts {
    public static let fileAccess: UInt16 = 5000
    public static let install: UInt16 = 6000
    public static let httpConfig: UInt16 = 1234
}

public enum WiFiLinkPhase: String, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed
    case unknown

    public var label: String {
        switch self {
        case .disconnected: "未连接"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .failed: "失败"
        case .unknown: "未知"
        }
    }

    public var symbol: String {
        switch self {
        case .disconnected: "wifi.slash"
        case .connecting: "wifi"
        case .connected: "wifi"
        case .failed: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

public enum WiFiObservation<Value: Sendable & Equatable>: Sendable, Equatable {
    case unknown
    case observed(Value)
}

public struct WiFiFTPSnapshot: Sendable, Equatable {
    public var phase: WiFiLinkPhase
    public var host: String
    public var port: UInt16?
    public var summary: String
    public var nextStep: String
    public var greeting: WiFiObservation<String>
    public var workingDirectory: WiFiObservation<String>
    public var listingText: WiFiObservation<String>

    public init(
        phase: WiFiLinkPhase,
        host: String,
        port: UInt16?,
        summary: String,
        nextStep: String,
        greeting: WiFiObservation<String>,
        workingDirectory: WiFiObservation<String>,
        listingText: WiFiObservation<String>
    ) {
        self.phase = phase
        self.host = host
        self.port = port
        self.summary = summary
        self.nextStep = nextStep
        self.greeting = greeting
        self.workingDirectory = workingDirectory
        self.listingText = listingText
    }

    public static let notConnected = WiFiFTPSnapshot(
        phase: .disconnected,
        host: "",
        port: nil,
        summary: "未连接。",
        nextStep: "在 Switch 上自行打开 DBI 的 Run FTP server，再填写主机。留空端口时使用文档中的 5000（SD 文件访问）。本应用不会远程打开 FTP，不会连接安装端口 6000，也不会打开 USB。",
        greeting: .unknown,
        workingDirectory: .unknown,
        listingText: .unknown
    )

    public static func connecting(host: String, port: UInt16) -> WiFiFTPSnapshot {
        WiFiFTPSnapshot(
            phase: .connecting,
            host: host,
            port: port,
            summary: "正在连接 \(host):\(port) 的 FTP 控制端口。",
            nextStep: "请稍候。这一步只建立读取用的 FTP 连接，不会打开 USB，不会上传，也不会读取已安装游戏。",
            greeting: .unknown,
            workingDirectory: .unknown,
            listingText: .unknown
        )
    }
}

public enum WiFiFTPRequest: Sendable, Equatable {
    case ready(host: String, port: UInt16)
    case rejected(WiFiFTPSnapshot)
}

public enum WiFiFTPEndpointParser {
    public static func parse(host rawHost: String, portText: String) -> WiFiFTPRequest {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let portField = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty {
            return .rejected(rejected(
                host: "",
                port: nil,
                summary: "还没有填写主机。",
                nextStep: "填写 Switch 的 IP 或主机名。本应用不会扫描局域网，也不会替你打开 DBI 的 FTP。"
            ))
        }
        if host.contains("://") || host.contains("/") || host.contains(":") || host.contains("@") || host.contains(where: \.isWhitespace) {
            return .rejected(rejected(
                host: host,
                port: nil,
                summary: "主机栏不能写网址、路径或端口。",
                nextStep: "只填写主机名或 IPv4 地址，端口写在旁边的栏里。留空端口表示 5000。不要把 http:// 或 ftp:// 贴进主机栏。"
            ))
        }
        let label = #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"#
        if host.count > 253 || host.range(of: label, options: .regularExpression) == nil {
            return .rejected(rejected(
                host: host,
                port: nil,
                summary: "无法使用这个主机名。",
                nextStep: "请改成 Switch 的 IPv4 地址或普通主机名。本应用不会扫描局域网。"
            ))
        }
        let port: UInt16
        if portField.isEmpty {
            port = DBIWiFiDocumentedPorts.fileAccess
        } else if let value = UInt16(portField), (1...65535).contains(value) {
            port = value
        } else {
            return .rejected(rejected(
                host: host,
                port: nil,
                summary: "端口不是 1 到 65535 的整数。",
                nextStep: "留空则使用文档中的文件访问端口 5000。不要填写安装端口 6000。"
            ))
        }
        if port == DBIWiFiDocumentedPorts.install {
            return .rejected(rejected(
                host: host,
                port: port,
                summary: "端口 6000 是 DBI 文档里的安装端口。",
                nextStep: "这里只做 5000 上的只读 SD 文件访问，不会连接 6000，也不会上传或安装。请把端口留空或改成 5000，并确认你已在 Switch 上打开 Run FTP server。"
            ))
        }
        return .ready(host: host, port: port)
    }

    private static func rejected(host: String, port: UInt16?, summary: String, nextStep: String) -> WiFiFTPSnapshot {
        WiFiFTPSnapshot(
            phase: .failed,
            host: host,
            port: port,
            summary: summary,
            nextStep: nextStep,
            greeting: .unknown,
            workingDirectory: .unknown,
            listingText: .unknown
        )
    }
}

enum WiFiFTPCommand {
    static let allowlist: Set<String> = ["USER anonymous", "PASS anonymous", "PWD", "PASV", "LIST", "QUIT"]

    static func allows(_ command: String) -> Bool {
        allowlist.contains(command)
    }
}

struct FTPReply: Equatable, Sendable {
    var code: Int
    var lines: [String]
    var text: String { lines.joined(separator: "\n") }
}

enum FTPAccumulated: Equatable {
    case reply(FTPReply)
    case malformed(String)
    case tooLarge
}

struct FTPReplyAccumulator {
    private(set) var buffer = Data()
    let limit: Int

    mutating func append(_ data: Data) {
        guard buffer.count < limit else { return }
        let room = limit - buffer.count
        buffer.append(data.prefix(room))
    }

    mutating func next() -> FTPAccumulated? {
        guard let newline = buffer.firstIndex(of: 10) else {
            return buffer.count >= limit ? .tooLarge : nil
        }
        let first = line(from: buffer.startIndex, to: newline)
        guard let code = code(of: first) else { return .malformed(first) }
        let continued = first.count > 3 && first[first.index(first.startIndex, offsetBy: 3)] == "-"
        if !continued {
            consume(through: newline)
            return .reply(FTPReply(code: code, lines: [first]))
        }
        let terminator = String(format: "%03d ", code)
        var lines = [first]
        var cursor = buffer.index(after: newline)
        while let mark = buffer[cursor...].firstIndex(of: 10) {
            let text = line(from: cursor, to: mark)
            lines.append(text)
            if text.hasPrefix(terminator) {
                consume(through: mark)
                return .reply(FTPReply(code: code, lines: lines))
            }
            cursor = buffer.index(after: mark)
        }
        return buffer.count >= limit ? .tooLarge : nil
    }

    private func line(from start: Data.Index, to newline: Data.Index) -> String {
        var end = newline
        if end > start, buffer[buffer.index(before: end)] == 13 { end = buffer.index(before: end) }
        return String(decoding: buffer[start..<end], as: UTF8.self)
    }

    private func code(of line: String) -> Int? {
        guard line.count >= 3 else { return nil }
        let digits = line.prefix(3)
        guard let code = Int(digits), digits.allSatisfy(\.isNumber) else { return nil }
        if line.count > 3 {
            let marker = line[line.index(line.startIndex, offsetBy: 3)]
            guard marker == " " || marker == "-" else { return nil }
        }
        return code
    }

    private mutating func consume(through newline: Data.Index) {
        buffer.removeSubrange(...newline)
    }
}

enum WiFiFTPParsing {
    static func workingDirectory(in reply: FTPReply) -> String? {
        guard reply.code == 257 else { return nil }
        for line in reply.lines where line.hasPrefix("257") {
            if let path = quotedPath(in: line) { return path }
        }
        return nil
    }

    static func quotedPath(in line: String) -> String? {
        guard let open = line.firstIndex(of: "\"") else { return nil }
        var path = ""
        var index = line.index(after: open)
        while index < line.endIndex {
            if line[index] == "\"" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "\"" {
                    path.append("\"")
                    index = line.index(after: next)
                    continue
                }
                return path
            }
            path.append(line[index])
            index = line.index(after: index)
        }
        return nil
    }

    static func passiveEndpoint(in reply: FTPReply) -> (host: String, port: UInt16)? {
        guard reply.code == 227, let open = reply.text.lastIndex(of: "("), let close = reply.text[open...].firstIndex(of: ")") else {
            return nil
        }
        let body = reply.text[reply.text.index(after: open)..<close]
        let octets = body.split(separator: ",", omittingEmptySubsequences: false).compactMap { UInt16($0) }
        guard octets.count == 6, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        let host = "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3])"
        let portNumber = Int(octets[4]) * 256 + Int(octets[5])
        guard let port = UInt16(exactly: portNumber) else { return nil }
        return (host, port)
    }
}

enum WiFiFTPLinkError: Error, Equatable {
    case refused
    case timedOut
    case closed
    case unusable(String)
}

protocol WiFiFTPByteChannel: Sendable {
    var peerAddress: String { get async }
    func read(maxBytes: Int, timeout: Duration) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

protocol WiFiFTPChannelOpening: Sendable {
    func open(host: String, port: UInt16, timeout: Duration) async throws -> any WiFiFTPByteChannel
}

struct WiFiFTPLimits: Sendable, Equatable {
    var ioTimeout: Duration = .seconds(5)
    var maxReplyBytes: Int = 8_192
    var maxListingBytes: Int = 32 * 1_024
}

struct WiFiFTPExchangeResult: Sendable {
    var snapshot: WiFiFTPSnapshot
    var commands: [String]
    var superseded: Bool
}

enum WiFiFTPExchange {
    static func run(
        opener: any WiFiFTPChannelOpening,
        host: String,
        port: UInt16,
        limits: WiFiFTPLimits,
        holdControl: @Sendable (any WiFiFTPByteChannel) async -> Bool
    ) async -> WiFiFTPExchangeResult {
        if port == DBIWiFiDocumentedPorts.install {
            return WiFiFTPExchangeResult(
                snapshot: WiFiFTPEndpointParser.parse(host: host, portText: String(port)).rejectedSnapshot,
                commands: [],
                superseded: false
            )
        }
        var observed = Observed(host: host, port: port)
        var control: (any WiFiFTPByteChannel)?
        var dataChannel: (any WiFiFTPByteChannel)?
        do {
            let channel = try await opener.open(host: host, port: port, timeout: limits.ioTimeout)
            control = channel
            guard await holdControl(channel) else {
                await channel.close()
                return WiFiFTPExchangeResult(snapshot: observed.snapshot(phase: .disconnected, summary: "连接已取消。", nextStep: WiFiFTPSnapshot.notConnected.nextStep), commands: observed.commands, superseded: true)
            }
            var accumulator = FTPReplyAccumulator(limit: limits.maxReplyBytes)
            let greeting = try await readReply(on: channel, accumulator: &accumulator, timeout: limits.ioTimeout)
            observed.greeting = .observed(greeting.text)
            guard greeting.code == 220 else {
                await channel.close()
                if greeting.code == 421 {
                    return finished(observed, phase: .failed, summary: "FTP 服务主动关闭了连接（421）。", nextStep: "请查看 Switch 上 DBI 是否仍停在 Run FTP server，确认后再试。不要改用 6000。这次没有读取目录，已安装游戏保持未知。")
                }
                return finished(observed, phase: .unknown, summary: "收到了 \(greeting.code)，这不是服务就绪的 220。", nextStep: "不能把这次应答当成已连接。请确认端口是 DBI 的 FTP 文件访问端口（默认 5000），而不是 HTTP \(DBIWiFiDocumentedPorts.httpConfig) 或安装端口 6000。目录和已安装游戏保持未知。")
            }
            try await send("USER anonymous", on: channel, observed: &observed)
            let userReply = try await readReply(on: channel, accumulator: &accumulator, timeout: limits.ioTimeout)
            let loggedIn: Bool
            switch userReply.code {
            case 230:
                loggedIn = true
            case 331:
                try await send("PASS anonymous", on: channel, observed: &observed)
                let passReply = try await readReply(on: channel, accumulator: &accumulator, timeout: limits.ioTimeout)
                if passReply.code == 230 || passReply.code == 202 {
                    loggedIn = true
                } else if passReply.code == 530 {
                    await channel.close()
                    return finished(observed, phase: .failed, summary: "FTP 服务拒绝了匿名登录（530）。", nextStep: anonymousRefusal)
                } else {
                    await channel.close()
                    return finished(observed, phase: .unknown, summary: "匿名密码的应答是 \(passReply.code)，无法判断登录是否成功。", nextStep: unrecognizedLogin)
                }
            case 530:
                await channel.close()
                return finished(observed, phase: .failed, summary: "FTP 服务拒绝了匿名登录（530）。", nextStep: anonymousRefusal)
            case 500, 502:
                loggedIn = false
            default:
                await channel.close()
                return finished(observed, phase: .unknown, summary: "USER 的应答是 \(userReply.code)，不能判断会话是否可用。", nextStep: unrecognizedLogin)
            }
            try await send("PWD", on: channel, observed: &observed)
            let pwd = try await readReply(on: channel, accumulator: &accumulator, timeout: limits.ioTimeout)
            if pwd.code == 257, let path = WiFiFTPParsing.workingDirectory(in: pwd) {
                observed.directory = .observed(path)
            } else if pwd.code == 530 && !loggedIn {
                await channel.close()
                return finished(observed, phase: .failed, summary: "服务器要求登录，但没有接受匿名 USER。", nextStep: anonymousRefusal)
            } else if !loggedIn && pwd.code != 257 {
                await channel.close()
                return finished(observed, phase: .unknown, summary: "没有完成登录，PWD 应答是 \(pwd.code)。", nextStep: unrecognizedLogin)
            }
            guard loggedIn || observed.directory != .unknown else {
                await channel.close()
                return finished(observed, phase: .unknown, summary: "控制连接没有进入可读取的状态。", nextStep: unrecognizedLogin)
            }
            try await send("PASV", on: channel, observed: &observed)
            let pasv = try await readReply(on: channel, accumulator: &accumulator, timeout: limits.ioTimeout)
            guard pasv.code == 227, let dataEndpoint = WiFiFTPParsing.passiveEndpoint(in: pasv) else {
                return finished(observed, phase: .connected, summary: "FTP 控制连接已建立，但服务器没有给出可用的被动数据地址。", nextStep: "目录列表保持未知。这不是已安装游戏清单。可以断开后重试；本页不会上传或安装。")
            }
            let peer = await channel.peerAddress
            guard dataEndpoint.host == peer else {
                return finished(observed, phase: .connected, summary: "FTP 控制连接已建立，但被动数据地址与当前连接不一致。", nextStep: "服务器给出的数据地址是 \(dataEndpoint.host)，当前连接的对端是 \(peer)。已拒绝跟随，避免连到别的主机。目录列表保持未知，这也不是已安装游戏清单。")
            }
            let data: any WiFiFTPByteChannel
            do {
                data = try await opener.open(host: peer, port: dataEndpoint.port, timeout: limits.ioTimeout)
            } catch let error as WiFiFTPLinkError {
                return finished(observed, phase: .connected, summary: "FTP 控制连接已建立，但数据连接没有打开。", nextStep: "被动端口 \(dataEndpoint.port) \(dataFailure(error))。目录列表保持未知，这不是已安装游戏。控制连接还在，可以断开后重试。本页不会上传或安装。")
            }
            dataChannel = data
            try await send("LIST", on: channel, observed: &observed)
            let preliminary = try await readReply(on: channel, accumulator: &accumulator, timeout: limits.ioTimeout)
            if preliminary.code == 150 || preliminary.code == 125 {
                let listing = try await readListing(on: data, limit: limits.maxListingBytes, timeout: limits.ioTimeout)
                await data.close()
                let final = try await readReply(on: channel, accumulator: &accumulator, timeout: limits.ioTimeout)
                guard final.code == 226 else {
                    return finished(observed, phase: .connected, summary: "已登录 FTP，但目录传输的结束应答是 \(final.code)。", nextStep: "目录内容保持未知，不能当成 SD 目录或已安装游戏。包身份也保持未知。")
                }
                apply(listing, to: &observed)
            } else if preliminary.code == 226 {
                await data.close()
                observed.listingText = .observed("")
            } else {
                await data.close()
                return finished(observed, phase: .connected, summary: "已登录 FTP，但 LIST 的应答是 \(preliminary.code)。", nextStep: "没有拿到目录文本。目录、已安装游戏和包身份都保持未知。")
            }
            return finished(observed, phase: .connected, summary: connectedSummary(observed), nextStep: connectedNextStep(observed))
        } catch let error as WiFiFTPWireError {
            if let dataChannel { await dataChannel.close() }
            if let control { await control.close() }
            return map(error, observed: observed, timeout: limits.ioTimeout)
        } catch let error as WiFiFTPLinkError {
            if let dataChannel { await dataChannel.close() }
            if let control { await control.close() }
            return map(.link(error), observed: observed, timeout: limits.ioTimeout)
        } catch {
            if let dataChannel { await dataChannel.close() }
            if let control { await control.close() }
            return finished(observed, phase: .unknown, summary: "连接在没有明确 FTP 结果时结束。", nextStep: "请核对主机、端口和 DBI 的 FTP 画面后重试。目录和已安装游戏保持未知。本应用不会扫描局域网，也不会打开 USB。")
        }
    }

    private static func dataFailure(_ error: WiFiFTPLinkError) -> String {
        switch error {
        case .refused: "拒绝了连接"
        case .timedOut: "在时限内没有接通"
        case .closed: "在传目录前被关闭"
        case .unusable: "无法使用"
        }
    }

    /// `nil` means QUIT was not written. `false` means it was written without a 221. `true` means the reply contained 221.
    static func quit(_ channel: any WiFiFTPByteChannel) async -> Bool? {
        do {
            try await channel.write(Data("QUIT\r\n".utf8))
        } catch {
            return nil
        }
        do {
            let data = try await channel.read(maxBytes: 512, timeout: .milliseconds(800))
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("221")
        } catch {
            return false
        }
    }

    private static let anonymousRefusal = "固定的 DBI 说明没有记载另一个账号。本应用不会尝试其他用户名或密码。请确认 Switch 上打开的是 DBI 的 Run FTP server。目录和已安装游戏保持未知。"
    private static let unrecognizedLogin = "请确认这是 DBI 的 FTP 文件访问端口（默认 5000）。不要改用安装端口 6000，也不要把 HTTP 响应当成清单。目录、已安装游戏和包身份保持未知。"

    private static func apply(_ listing: ListingRead, to observed: inout Observed) {
        guard !listing.truncated, let text = String(data: listing.bytes, encoding: .utf8) else {
            observed.listingText = .unknown
            return
        }
        observed.listingText = .observed(text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    private static func connectedSummary(_ observed: Observed) -> String {
        switch observed.listingText {
        case .observed(let text) where text.isEmpty:
            "已连上 FTP，LIST 返回了空文本。"
        case .observed:
            "已连上 FTP 控制连接，并收到当前目录的 LIST 原文。"
        case .unknown:
            "已连上 FTP 控制连接，但目录文本不可用。"
        }
    }

    private static func connectedNextStep(_ observed: Observed) -> String {
        switch observed.listingText {
        case .observed(let text) where text.isEmpty:
            "空文本只说明这次 LIST 没有正文，不能说明 SD 上没有文件，也不能说明没有已安装游戏。包身份保持未知。需要结束时请断开。本页不会上传或安装。"
        case .observed:
            "这些文字只是这次 FTP LIST 的原文。文档把端口 5000 描述为 SD 文件访问，但这次结果不能证明对端就是 DBI，也不是已安装游戏，也不能用来确认包身份。需要结束时请断开。本页不会上传、续传或写入。"
        case .unknown:
            "目录列表超出了读取上限，或不是可显示的文本，因此保持未知。这不是完整目录，也不是已安装游戏。可以断开后重试。本页不会上传或安装。"
        }
    }

    private static func finished(_ observed: Observed, phase: WiFiLinkPhase, summary: String, nextStep: String) -> WiFiFTPExchangeResult {
        var snapshot = observed.snapshot(phase: phase, summary: summary, nextStep: nextStep)
        if phase != .connected { snapshot.phase = phase }
        return WiFiFTPExchangeResult(snapshot: snapshot, commands: observed.commands, superseded: false)
    }

    private static func map(_ error: WiFiFTPWireError, observed: Observed, timeout: Duration) -> WiFiFTPExchangeResult {
        switch error {
        case .malformed(let line):
            if case .observed = observed.greeting {
                return finished(observed, phase: .unknown, summary: "已经收到 FTP 问候，但后面的应答无法识别。", nextStep: "目录和已安装游戏保持未知。请确认对端仍是 DBI 的 FTP，然后断开再试。不要把无法识别的字节当成清单。")
            }
            let http = line.hasPrefix("HTTP/")
            let summary = http ? "这个端口返回了 HTTP，而不是 FTP。" : "端口有数据返回，但不是可识别的 FTP 应答。"
            let next = http
                ? "DBI 配置里的 HTTP 端口是 \(DBIWiFiDocumentedPorts.httpConfig)，但 647 的可查询元数据接口尚未验证，所以不会把这次响应当成清单。请改用 FTP 文件访问端口 5000。已安装游戏和包身份保持未知。"
                : "请确认端口是 DBI 的 FTP 文件访问端口（默认 5000），而不是 HTTP \(DBIWiFiDocumentedPorts.httpConfig) 或安装端口 6000。这次没有读取目录。已安装游戏保持未知。"
            return finished(observed, phase: .unknown, summary: summary, nextStep: next)
        case .tooLarge:
            return finished(observed, phase: .unknown, summary: "FTP 应答超过了读取上限，内容不完整。", nextStep: "不能把截断的应答当成连接成功或目录。请断开后重试。已安装游戏保持未知。")
        case .link(.refused):
            return finished(observed, phase: .failed, summary: "没有连上 \(observed.host):\(observed.port)。TCP 连接被拒绝或无法到达。", nextStep: "请核对主机地址，并确认你已经在 Switch 上打开 DBI 的 Run FTP server。文件访问端口是 5000；6000 是安装端口，本页不会使用。连接被拒绝不能说明设备里没有游戏。本应用不会扫描局域网，也不会替你打开 FTP。")
        case .link(.timedOut):
            return finished(observed, phase: .failed, summary: "在 \(timeoutPhrase(timeout)) 内没有完成这次 FTP 通信。", nextStep: "请确认 Mac 和 Switch 在同一网络、DBI 仍停在 FTP 画面，以及主机和端口无误。若刚打开 FTP，等画面稳定后再手动试一次。不要改用 6000，这里不会上传或安装。超时后目录和已安装内容都保持未知。")
        case .link(.closed):
            return finished(observed, phase: .failed, summary: "FTP 连接在应答完成前被关闭。", nextStep: "请查看 Switch 上 DBI 是否退出了 FTP。重新打开 Run FTP server 后再试。已经看到的应答以外都保持未知，这不能说明已安装游戏的情况。")
        case .link(.unusable(let message)):
            return finished(observed, phase: .failed, summary: "无法解析或使用主机「\(observed.host)」。", nextStep: "\(message) 请填写 Switch 的 IP 地址。本应用不会扫描局域网，也不会打开 USB。")
        }
    }

    private static func timeoutPhrase(_ duration: Duration) -> String {
        let ms = max(duration.milliseconds, 0)
        if ms % 1000 == 0 { return "\(ms / 1000) 秒" }
        return "\(ms) 毫秒"
    }

    private static func send(_ command: String, on channel: any WiFiFTPByteChannel, observed: inout Observed) async throws {
        precondition(WiFiFTPCommand.allows(command), "FTP command is outside the read-only allowlist")
        observed.commands.append(command)
        try await channel.write(Data((command + "\r\n").utf8))
    }

    private static func readReply(on channel: any WiFiFTPByteChannel, accumulator: inout FTPReplyAccumulator, timeout: Duration) async throws -> FTPReply {
        if let ready = try take(from: &accumulator) { return ready }
        while true {
            let chunk: Data
            do {
                chunk = try await channel.read(maxBytes: 1_024, timeout: timeout)
            } catch let error as WiFiFTPLinkError {
                throw WiFiFTPWireError.link(error)
            }
            if chunk.isEmpty { throw WiFiFTPWireError.link(.closed) }
            accumulator.append(chunk)
            if let ready = try take(from: &accumulator) { return ready }
        }
    }

    private static func take(from accumulator: inout FTPReplyAccumulator) throws -> FTPReply? {
        switch accumulator.next() {
        case .reply(let reply): return reply
        case .malformed(let line): throw WiFiFTPWireError.malformed(line)
        case .tooLarge: throw WiFiFTPWireError.tooLarge
        case nil: return nil
        }
    }

    private static func readListing(on channel: any WiFiFTPByteChannel, limit: Int, timeout: Duration) async throws -> ListingRead {
        var bytes = Data()
        while bytes.count < limit {
            let chunk: Data
            do {
                chunk = try await channel.read(maxBytes: min(4_096, limit - bytes.count), timeout: timeout)
            } catch let error as WiFiFTPLinkError {
                throw WiFiFTPWireError.link(error)
            }
            if chunk.isEmpty { return ListingRead(bytes: bytes, truncated: false) }
            bytes.append(chunk)
        }
        let extra: Data
        do {
            extra = try await channel.read(maxBytes: 1, timeout: timeout)
        } catch let error as WiFiFTPLinkError {
            throw WiFiFTPWireError.link(error)
        }
        return ListingRead(bytes: bytes, truncated: !extra.isEmpty)
    }
}

private struct ListingRead {
    var bytes: Data
    var truncated: Bool
}

private struct Observed {
    var host: String
    var port: UInt16
    var greeting: WiFiObservation<String> = .unknown
    var directory: WiFiObservation<String> = .unknown
    var listingText: WiFiObservation<String> = .unknown
    var commands: [String] = []

    func snapshot(phase: WiFiLinkPhase, summary: String, nextStep: String) -> WiFiFTPSnapshot {
        WiFiFTPSnapshot(
            phase: phase,
            host: host,
            port: port,
            summary: summary,
            nextStep: nextStep,
            greeting: greeting,
            workingDirectory: directory,
            listingText: listingText
        )
    }
}

private enum WiFiFTPWireError: Error {
    case malformed(String)
    case tooLarge
    case link(WiFiFTPLinkError)
}

private extension WiFiFTPRequest {
    var rejectedSnapshot: WiFiFTPSnapshot {
        if case .rejected(let snapshot) = self { return snapshot }
        return WiFiFTPSnapshot.notConnected
    }
}

extension Duration {
    var milliseconds: Int {
        let parts = components
        return Int(parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)
    }
}
