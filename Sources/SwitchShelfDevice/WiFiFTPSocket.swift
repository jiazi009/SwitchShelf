import Darwin
import Foundation

struct POSIXWiFiFTPOpener: WiFiFTPChannelOpening {
    func open(host: String, port: UInt16, timeout: Duration) async throws -> any WiFiFTPByteChannel {
        if port == DBIWiFiDocumentedPorts.install {
            throw WiFiFTPLinkError.refused
        }
        let opened = try await Task.detached(priority: .userInitiated) {
            try POSIXWiFiConnect.open(host: host, port: port, timeout: timeout)
        }.value
        return POSIXWiFiChannel(fd: opened.fd, peerAddress: opened.peer)
    }
}

actor POSIXWiFiChannel: WiFiFTPByteChannel {
    let peerAddress: String
    private let box: WiFiSocketBox

    init(fd: Int32, peerAddress: String) {
        self.box = WiFiSocketBox(fd)
        self.peerAddress = peerAddress
    }

    deinit { box.shutdownAndClose() }

    func read(maxBytes: Int, timeout: Duration) async throws -> Data {
        let fd = box.current
        guard fd >= 0 else { throw WiFiFTPLinkError.closed }
        return try await Task.detached {
            try POSIXWiFiIO.readSome(fd: fd, maxBytes: maxBytes, timeout: timeout)
        }.value
    }

    func write(_ data: Data) async throws {
        let fd = box.current
        guard fd >= 0 else { throw WiFiFTPLinkError.closed }
        let payload = data
        try await Task.detached {
            try POSIXWiFiIO.writeAll(fd: fd, data: payload, timeout: .seconds(5))
        }.value
    }

    func close() async {
        box.shutdownAndClose()
    }
}

private struct OpenedSocket: Sendable {
    var fd: Int32
    var peer: String
}

private enum POSIXWiFiConnect {
    static func open(host: String, port: UInt16, timeout: Duration) throws -> OpenedSocket {
        var hints = addrinfo()
        memset(&hints, 0, MemoryLayout<addrinfo>.size)
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        let numericIPv4 = host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { UInt8($0) != nil }
        hints.ai_family = numericIPv4 ? AF_INET : AF_UNSPEC
        hints.ai_flags = numericIPv4 ? AI_NUMERICHOST : AI_ADDRCONFIG
        var info: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &info)
        if status != 0 {
            if status == EAI_AGAIN { throw WiFiFTPLinkError.timedOut }
            throw WiFiFTPLinkError.unusable("系统无法解析这个主机名。")
        }
        defer { if let info { freeaddrinfo(info) } }
        guard let info else { throw WiFiFTPLinkError.unusable("系统没有返回可用地址。") }
        let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw mapSocketErrno() }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        let connected = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
        if connected < 0 && errno != EINPROGRESS {
            let error = mapSocketErrno()
            _ = Darwin.close(fd)
            throw error
        }
        if connected < 0 {
            do {
                try POSIXWiFiIO.wait(fd: fd, events: POLLOUT, timeout: timeout)
            } catch {
                _ = Darwin.close(fd)
                throw error
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
            if socketError != 0 {
                _ = Darwin.close(fd)
                throw mapSocketErrno(socketError)
            }
        }
        return OpenedSocket(fd: fd, peer: peerAddress(fd))
    }

    private static func peerAddress(_ fd: Int32) -> String {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
        }
        guard result == 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let named = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard named == 0 else { return "" }
        let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if host.hasPrefix("::ffff:") { return String(host.dropFirst("::ffff:".count)) }
        return host
    }
}

private enum POSIXWiFiIO {
    static func readSome(fd: Int32, maxBytes: Int, timeout: Duration) throws -> Data {
        guard maxBytes > 0 else { return Data() }
        try wait(fd: fd, events: POLLIN, timeout: timeout)
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let count = buffer.withUnsafeMutableBytes { raw in
            Darwin.recv(fd, raw.baseAddress, maxBytes, 0)
        }
        if count > 0 { return Data(buffer.prefix(count)) }
        if count == 0 { return Data() }
        if errno == EAGAIN || errno == EWOULDBLOCK { throw WiFiFTPLinkError.timedOut }
        throw mapSocketErrno()
    }

    static func writeAll(fd: Int32, data: Data, timeout: Duration) throws {
        var offset = 0
        let bytes = [UInt8](data)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while offset < bytes.count {
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero { throw WiFiFTPLinkError.timedOut }
            try wait(fd: fd, events: POLLOUT, timeout: remaining)
            let written = bytes.withUnsafeBytes { raw in
                Darwin.send(fd, raw.baseAddress! + offset, bytes.count - offset, 0)
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { continue }
            throw mapSocketErrno()
        }
    }

    static func wait(fd: Int32, events: Int32, timeout: Duration) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            let remaining = clock.now.duration(to: deadline).milliseconds
            if remaining <= 0 { throw WiFiFTPLinkError.timedOut }
            var pollFD = pollfd(fd: fd, events: Int16(events), revents: 0)
            let result = Darwin.poll(&pollFD, 1, Int32(min(remaining, Int(Int32.max))))
            if result == 0 { throw WiFiFTPLinkError.timedOut }
            if result < 0 {
                if errno == EINTR { continue }
                throw mapSocketErrno()
            }
            let ready = Int32(pollFD.revents)
            if ready & events != 0 { return }
            if ready & (POLLERR | POLLHUP | POLLNVAL) != 0 { throw WiFiFTPLinkError.closed }
        }
    }
}

private final class WiFiSocketBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    init(_ fd: Int32) { self.fd = fd }

    var current: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    func shutdownAndClose() {
        lock.lock()
        let open = fd
        fd = -1
        lock.unlock()
        guard open >= 0 else { return }
        _ = Darwin.shutdown(open, SHUT_RDWR)
        _ = Darwin.close(open)
    }
}

private func mapSocketErrno(_ value: Int32 = errno) -> WiFiFTPLinkError {
    switch value {
    case ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ECONNABORTED:
        return .refused
    case ETIMEDOUT:
        return .timedOut
    case EPIPE, ECONNRESET, ENOTCONN, EBADF:
        return .closed
    default:
        return .unusable("系统错误 \(value)。")
    }
}
