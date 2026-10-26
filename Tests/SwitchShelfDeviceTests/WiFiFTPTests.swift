import Darwin
import Foundation
import Testing
@testable import SwitchShelfDevice

@Suite("DBI FTP endpoint — local validation, no socket")
struct WiFiFTPEndpointTests {
    @Test func blankPortUsesDocumentedFileAccessPort() {
        guard case .ready(let host, let port) = WiFiFTPEndpointParser.parse(host: "127.0.0.1", portText: "  ") else {
            Issue.record("expected a ready endpoint")
            return
        }
        #expect(host == "127.0.0.1")
        #expect(port == DBIWiFiDocumentedPorts.fileAccess)
        #expect(port == 5000)
    }

    @Test func installPortIsRejectedBeforeAnyConnection() {
        guard case .rejected(let snapshot) = WiFiFTPEndpointParser.parse(host: "10.0.0.8", portText: "6000") else {
            Issue.record("6000 must be rejected")
            return
        }
        #expect(snapshot.phase == .failed)
        #expect(snapshot.port == 6000)
        #expect(snapshot.nextStep.contains("不会连接 6000"))
        #expect(snapshot.listingText == .unknown)
    }

    @Test func paddedInstallPortIsStillRejected() {
        guard case .rejected(let snapshot) = WiFiFTPEndpointParser.parse(host: "10.0.0.8", portText: "06000") else {
            Issue.record("06000 is still the install port")
            return
        }
        #expect(snapshot.port == 6000)
    }

    @Test func urlAndEmptyHostDoNotBecomeEndpoints() {
        guard case .rejected(let empty) = WiFiFTPEndpointParser.parse(host: "  ", portText: "") else {
            Issue.record("empty host")
            return
        }
        #expect(empty.summary.contains("主机"))
        #expect(empty.nextStep.contains("不会扫描"))
        guard case .rejected(let url) = WiFiFTPEndpointParser.parse(host: "ftp://10.0.0.8", portText: "") else {
            Issue.record("url host")
            return
        }
        #expect(url.phase == .failed)
        #expect(url.nextStep.contains("端口"))
    }

    @Test func readOnlyAllowlistExcludesWrites() {
        #expect(WiFiFTPCommand.allows("LIST"))
        #expect(WiFiFTPCommand.allows("PWD"))
        #expect(!WiFiFTPCommand.allows("STOR file.nsp"))
        #expect(!WiFiFTPCommand.allows("RETR file.nsp"))
        #expect(!WiFiFTPCommand.allows("APPE file.nsp"))
        #expect(!WiFiFTPCommand.allows("DELE file.nsp"))
        #expect(!WiFiFTPCommand.allows("PORT 127,0,0,1,0,1"))
        #expect(!WiFiFTPCommand.allows("CWD /"))
    }
}

@Suite("FTP reply parsing")
struct WiFiFTPParsingTests {
    @Test func splitAndMultilineReplies() {
        var accumulator = FTPReplyAccumulator(limit: 512)
        #expect(accumulator.next() == nil)
        accumulator.append(Data("22".utf8))
        #expect(accumulator.next() == nil)
        accumulator.append(Data("0-DBI\r\n220 ready\r\n257 ".utf8))
        guard case .reply(let greeting) = accumulator.next() else {
            Issue.record("multiline greeting")
            return
        }
        #expect(greeting.code == 220)
        #expect(greeting.lines.count == 2)
        accumulator.append(Data("\"/\"\r\n".utf8))
        guard case .reply(let pwd) = accumulator.next() else {
            Issue.record("pwd leftover")
            return
        }
        #expect(WiFiFTPParsing.workingDirectory(in: pwd) == "/")
    }

    @Test func quotedPathKeepsEscapedQuotes() {
        let reply = FTPReply(code: 257, lines: ["257 \"/sd\"\"card\" is current"])
        #expect(WiFiFTPParsing.workingDirectory(in: reply) == "/sd\"card")
    }

    @Test func unquoted257StaysUnknown() {
        let reply = FTPReply(code: 257, lines: ["257 current"])
        #expect(WiFiFTPParsing.workingDirectory(in: reply) == nil)
    }

    @Test func passiveEndpointUsesLastTuple() {
        let reply = FTPReply(code: 227, lines: ["227 Entering Passive Mode (127,0,0,1,195,80)"])
        #expect(WiFiFTPParsing.passiveEndpoint(in: reply)?.host == "127.0.0.1")
        #expect(WiFiFTPParsing.passiveEndpoint(in: reply)?.port == UInt16(50_000))
        let bad = FTPReply(code: 227, lines: ["227 no address"])
        #expect(WiFiFTPParsing.passiveEndpoint(in: bad) == nil)
    }

    @Test func httpBannerIsMalformed() {
        var accumulator = FTPReplyAccumulator(limit: 256)
        accumulator.append(Data("HTTP/1.1 200 OK\r\n".utf8))
        guard case .malformed(let line) = accumulator.next() else {
            Issue.record("expected malformed")
            return
        }
        #expect(line.hasPrefix("HTTP/"))
    }
}

@Suite("DBI FTP session — scripted channels, no network")
struct WiFiFTPScriptedSessionTests {
    @Test func successKeepsListingRawAndLeavesIdentityUnknown() async {
        let listing = "game [0100AAA000000000][v65536][BASE].nsp\n"
        let opener = ScriptedOpener(
            control: ScriptChannel(peer: "127.0.0.1", chunks: [
                .success(Data("220 fixture ready\r\n".utf8)),
                .success(Data("331 password\r\n".utf8)),
                .success(Data("230 logged in\r\n".utf8)),
                .success(Data("257 \"/\" is current\r\n".utf8)),
                .success(Data("227 Entering Passive Mode (127,0,0,1,1,2)\r\n".utf8)),
                .success(Data("150 opening\r\n".utf8)),
                .success(Data("226 done\r\n".utf8))
            ]),
            data: ScriptChannel(peer: "127.0.0.1", chunks: [
                .success(Data(listing.utf8)),
                .success(Data())
            ])
        )
        let client = WiFiFTPClient(opener: opener, limits: WiFiFTPLimits(ioTimeout: .seconds(1)))
        let snapshot = await client.connect(host: "127.0.0.1", port: 5000)
        #expect(snapshot.phase == .connected)
        #expect(snapshot.greeting == .observed("220 fixture ready"))
        #expect(snapshot.workingDirectory == .observed("/"))
        #expect(snapshot.listingText == .observed(listing))
        #expect(snapshot.nextStep.contains("不是已安装游戏"))
        #expect(await client.lastCommands == ["USER anonymous", "PASS anonymous", "PWD", "PASV", "LIST"])
        #expect(await opener.ports == [5000, 258])
        let closed = await client.disconnect()
        #expect(closed.phase == .disconnected)
        #expect(closed.listingText == .unknown)
        #expect(await client.lastCommands.contains("QUIT"))
    }

    @Test func anonymousRefusalDoesNotTryAnotherAccount() async {
        let opener = ScriptedOpener(control: ScriptChannel(peer: "127.0.0.1", chunks: [
            .success(Data("220 ready\r\n".utf8)),
            .success(Data("530 denied\r\n".utf8))
        ]))
        let client = WiFiFTPClient(opener: opener)
        let snapshot = await client.connect(hostText: "127.0.0.1", portText: "")
        #expect(snapshot.phase == .failed)
        #expect(snapshot.port == 5000)
        #expect(snapshot.nextStep.contains("不会尝试其他用户名"))
        #expect(snapshot.listingText == .unknown)
        #expect(await client.lastCommands == ["USER anonymous"])
        #expect(await opener.ports == [5000])
    }

    @Test func timeoutKeepsLaterFieldsUnknown() async {
        let opener = ScriptedOpener(control: ScriptChannel(peer: "10.0.0.2", chunks: [
            .success(Data("220 ready\r\n".utf8)),
            .failure(.timedOut)
        ]))
        let client = WiFiFTPClient(opener: opener, limits: WiFiFTPLimits(ioTimeout: .milliseconds(400)))
        let snapshot = await client.connect(host: "10.0.0.2", port: 5000)
        #expect(snapshot.phase == .failed)
        #expect(snapshot.greeting == .observed("220 ready"))
        #expect(snapshot.workingDirectory == .unknown)
        #expect(snapshot.listingText == .unknown)
        #expect(snapshot.summary.contains("400 毫秒"))
        #expect(snapshot.nextStep.contains("保持未知"))
        #expect(snapshot.nextStep.contains("不会上传"))
    }

    @Test func httpResponseStaysUnknown() async {
        let opener = ScriptedOpener(control: ScriptChannel(peer: "127.0.0.1", chunks: [
            .success(Data("HTTP/1.1 200 OK\r\n".utf8))
        ]))
        let client = WiFiFTPClient(opener: opener)
        let snapshot = await client.connect(host: "127.0.0.1", port: 1234)
        #expect(snapshot.phase == .unknown)
        #expect(snapshot.summary.contains("HTTP"))
        #expect(snapshot.nextStep.contains("尚未验证"))
        #expect(snapshot.nextStep.contains("5000"))
        #expect(await client.lastCommands.isEmpty)
    }

    @Test func unknownGreetingIsNotConnected() async {
        let opener = ScriptedOpener(control: ScriptChannel(peer: "127.0.0.1", chunks: [
            .success(Data("HELLO\r\n".utf8))
        ]))
        let client = WiFiFTPClient(opener: opener)
        let snapshot = await client.connect(host: "127.0.0.1", port: 5000)
        #expect(snapshot.phase == .unknown)
        #expect(snapshot.listingText == .unknown)
        #expect(snapshot.nextStep.contains("5000"))
    }

    @Test func passiveAddressMismatchDoesNotOpenData() async {
        let opener = ScriptedOpener(control: ScriptChannel(peer: "127.0.0.1", chunks: [
            .success(Data("220 ready\r\n".utf8)),
            .success(Data("230 in\r\n".utf8)),
            .success(Data("257 \"/switch\"\r\n".utf8)),
            .success(Data("227 Entering Passive Mode (10,1,2,3,4,5)\r\n".utf8))
        ]))
        let client = WiFiFTPClient(opener: opener)
        let snapshot = await client.connect(host: "127.0.0.1", port: 5000)
        #expect(snapshot.phase == .connected)
        #expect(snapshot.workingDirectory == .observed("/switch"))
        #expect(snapshot.listingText == .unknown)
        #expect(snapshot.nextStep.contains("已拒绝跟随"))
        #expect(await opener.ports == [5000])
        #expect(await client.lastCommands == ["USER anonymous", "PWD", "PASV"])
    }

    @Test func emptyListingIsNotAnEmptyInstallSet() async {
        let opener = ScriptedOpener(
            control: ScriptChannel(peer: "127.0.0.1", chunks: [
                .success(Data("220 ready\r\n".utf8)),
                .success(Data("230 in\r\n".utf8)),
                .success(Data("257 \"/\"\r\n".utf8)),
                .success(Data("227 Entering Passive Mode (127,0,0,1,0,9)\r\n".utf8)),
                .success(Data("150 go\r\n".utf8)),
                .success(Data("226 done\r\n".utf8))
            ]),
            data: ScriptChannel(peer: "127.0.0.1", chunks: [.success(Data())])
        )
        let client = WiFiFTPClient(opener: opener)
        let snapshot = await client.connect(host: "127.0.0.1", port: 5000)
        #expect(snapshot.phase == .connected)
        #expect(snapshot.listingText == .observed(""))
        #expect(snapshot.nextStep.contains("不能说明没有已安装游戏"))
    }

    @Test func installPortNeverOpensAChannel() async {
        let opener = ScriptedOpener(control: ScriptChannel(peer: "127.0.0.1", chunks: []))
        let client = WiFiFTPClient(opener: opener)
        let snapshot = await client.connect(host: "127.0.0.1", port: 6000)
        #expect(snapshot.phase == .failed)
        #expect(await opener.ports.isEmpty)
        #expect(await client.lastCommands.isEmpty)
    }

    @Test func connectionRefusedNamesTheNextCheck() async {
        let opener = ScriptedOpener(control: ScriptChannel(peer: "127.0.0.1", chunks: [.failure(.refused)]))
        let client = WiFiFTPClient(opener: opener)
        let snapshot = await client.connect(host: "192.168.1.20", port: 5000)
        #expect(snapshot.phase == .failed)
        #expect(snapshot.summary.contains("被拒绝"))
        #expect(snapshot.nextStep.contains("Run FTP server"))
        #expect(snapshot.nextStep.contains("不能说明设备里没有游戏"))
        #expect(snapshot.listingText == .unknown)
    }
}

@Suite("DBI FTP session — loopback fixture server, not a Switch")
struct WiFiFTPLoopbackTests {
    @Test func loopbackDialogueThenQuit() async throws {
        let server = LoopbackFTPServer(.dialogue("readme.txt\r\n"))
        try server.start()
        defer { server.stop() }
        let client = WiFiFTPClient(limits: WiFiFTPLimits(ioTimeout: .seconds(2)))
        let snapshot = await client.connect(host: "127.0.0.1", port: server.port)
        #expect(snapshot.phase == .connected)
        #expect(snapshot.listingText == .observed("readme.txt\n"))
        #expect(snapshot.workingDirectory == .observed("/"))
        #expect(snapshot.nextStep.contains("不是已安装游戏"))
        let closed = await client.disconnect()
        #expect(closed.phase == .disconnected)
        #expect(closed.nextStep.contains("221"))
    }

    @Test func loopbackLoginRefusal() async throws {
        let server = LoopbackFTPServer(.rejectLogin)
        try server.start()
        defer { server.stop() }
        let client = WiFiFTPClient(limits: WiFiFTPLimits(ioTimeout: .seconds(2)))
        let snapshot = await client.connect(host: "127.0.0.1", port: server.port)
        #expect(snapshot.phase == .failed)
        #expect(snapshot.summary.contains("530"))
        #expect(snapshot.listingText == .unknown)
    }

    @Test func loopbackSilenceTimesOut() async throws {
        let server = LoopbackFTPServer(.silence)
        try server.start()
        defer { server.stop() }
        let client = WiFiFTPClient(limits: WiFiFTPLimits(ioTimeout: .milliseconds(300)))
        let snapshot = await client.connect(host: "127.0.0.1", port: server.port)
        #expect(snapshot.phase == .failed)
        #expect(snapshot.summary.contains("300 毫秒"))
        #expect(snapshot.nextStep.contains("保持未知"))
        #expect(snapshot.greeting == .unknown)
    }

    @Test func loopbackUnknownBanner() async throws {
        let server = LoopbackFTPServer(.unknownBanner)
        try server.start()
        defer { server.stop() }
        let client = WiFiFTPClient(limits: WiFiFTPLimits(ioTimeout: .seconds(2)))
        let snapshot = await client.connect(host: "127.0.0.1", port: server.port)
        #expect(snapshot.phase == .unknown)
        #expect(snapshot.summary.contains("不是可识别的 FTP"))
        #expect(snapshot.listingText == .unknown)
    }

    @Test func closedPortIsRefusalNotAnEmptyDevice() async throws {
        let server = LoopbackFTPServer(.unknownBanner)
        try server.start()
        let port = server.port
        server.stop()
        let client = WiFiFTPClient(limits: WiFiFTPLimits(ioTimeout: .milliseconds(500)))
        let snapshot = await client.connect(host: "127.0.0.1", port: port)
        #expect(snapshot.phase == .failed)
        #expect(snapshot.listingText == .unknown)
        #expect(snapshot.greeting == .unknown)
        #expect(snapshot.nextStep.contains("保持未知") || snapshot.nextStep.contains("不能说明"))
    }
}

private actor ScriptChannel: WiFiFTPByteChannel {
    let peerAddress: String
    private var chunks: [Result<Data, WiFiFTPLinkError>]
    private var closed = false

    init(peer: String, chunks: [Result<Data, WiFiFTPLinkError>]) {
        self.peerAddress = peer
        self.chunks = chunks
    }

    func read(maxBytes: Int, timeout: Duration) async throws -> Data {
        if closed { throw WiFiFTPLinkError.closed }
        guard !chunks.isEmpty else { return Data() }
        let next = try chunks.removeFirst().get()
        guard next.count > maxBytes else { return next }
        let head = Data(next.prefix(maxBytes))
        chunks.insert(.success(Data(next.dropFirst(maxBytes))), at: 0)
        return head
    }

    func write(_ data: Data) async throws {
        if closed { throw WiFiFTPLinkError.closed }
    }

    func close() async {
        closed = true
    }
}

private actor ScriptedOpener: WiFiFTPChannelOpening {
    let control: ScriptChannel
    let data: ScriptChannel?
    private(set) var ports: [UInt16] = []

    init(control: ScriptChannel, data: ScriptChannel? = nil) {
        self.control = control
        self.data = data
    }

    func open(host: String, port: UInt16, timeout: Duration) async throws -> any WiFiFTPByteChannel {
        ports.append(port)
        if ports.count == 1 { return control }
        if let data { return data }
        throw WiFiFTPLinkError.refused
    }
}

private final class LoopbackFTPServer: @unchecked Sendable {
    enum Behavior {
        case dialogue(String)
        case silence
        case unknownBanner
        case rejectLogin
    }

    let behavior: Behavior
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var didStop = false

    init(_ behavior: Behavior) { self.behavior = behavior }

    func start() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            _ = Darwin.close(fd)
            throw URLError(.cannotConnectToHost)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listenFD = fd
        Thread { self.serve() }.start()
    }

    func stop() {
        lock.lock()
        if didStop {
            lock.unlock()
            return
        }
        didStop = true
        let listen = listenFD
        let client = clientFD
        listenFD = -1
        clientFD = -1
        lock.unlock()
        if listen >= 0 {
            _ = Darwin.shutdown(listen, SHUT_RDWR)
            _ = Darwin.close(listen)
        }
        if client >= 0 {
            _ = Darwin.shutdown(client, SHUT_RDWR)
            _ = Darwin.close(client)
        }
        finished.wait()
    }

    private func serve() {
        defer { finished.signal() }
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let accepted = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &length) }
        }
        guard accepted >= 0 else { return }
        lock.lock()
        clientFD = accepted
        lock.unlock()
        switch behavior {
        case .silence:
            var pollFD = pollfd(fd: accepted, events: Int16(POLLIN), revents: 0)
            _ = Darwin.poll(&pollFD, 1, 3_000)
        case .unknownBanner:
            _ = write("HELLO\r\n", fd: accepted)
        case .rejectLogin:
            guard write("220 fixture\r\n", fd: accepted), readLine(accepted) != nil else { break }
            _ = write("530 denied\r\n", fd: accepted)
        case .dialogue(let listing):
            guard write("220 fixture ready\r\n", fd: accepted), readLine(accepted)?.hasPrefix("USER") == true else { break }
            guard write("331 password\r\n", fd: accepted), readLine(accepted)?.hasPrefix("PASS") == true else { break }
            guard write("230 logged in\r\n", fd: accepted), readLine(accepted)?.hasPrefix("PWD") == true else { break }
            guard write("257 \"/\" is current\r\n", fd: accepted), readLine(accepted)?.hasPrefix("PASV") == true else { break }
            guard let data = listenData() else { break }
            let high = Int(data.port) / 256
            let low = Int(data.port) % 256
            guard write("227 Entering Passive Mode (127,0,0,1,\(high),\(low))\r\n", fd: accepted) else { break }
            guard readLine(accepted)?.hasPrefix("LIST") == true else { break }
            let payload = Darwin.accept(data.fd, nil, nil)
            guard write("150 opening\r\n", fd: accepted) else { break }
            if payload >= 0 {
                _ = write(listing, fd: payload)
                _ = Darwin.close(payload)
            }
            _ = Darwin.close(data.fd)
            guard write("226 done\r\n", fd: accepted) else { break }
            if readLine(accepted)?.hasPrefix("QUIT") == true {
                _ = write("221 bye\r\n", fd: accepted)
            }
        }
        _ = Darwin.close(accepted)
    }

    private func listenData() -> (fd: Int32, port: UInt16)? {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            _ = Darwin.close(fd)
            return nil
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private func readLine(_ fd: Int32) -> String? {
        var collected = Data()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(deadline.timeIntervalSinceNow * 1000, 1))
            if Darwin.poll(&pollFD, 1, left) <= 0 { return nil }
            var byte: UInt8 = 0
            let count = Darwin.recv(fd, &byte, 1, 0)
            if count <= 0 { return nil }
            if byte == 10 {
                return String(data: collected, encoding: .utf8)
            }
            if byte != 13 { collected.append(byte) }
            if collected.count > 400 { return nil }
        }
        return nil
    }

    private func write(_ text: String, fd: Int32) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress! + offset, bytes.count - offset, 0)
            }
            if count > 0 { offset += count; continue }
            return false
        }
        return true
    }
}
