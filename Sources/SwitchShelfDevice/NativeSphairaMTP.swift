import CDBIBridge
import Foundation

protocol SphairaUSBLink: Sendable {
    var packetSize: Int { get }
    func write(_ bytes: Data) async throws
    func read() async throws -> Data
    func close() async throws
}

struct SphairaNativeError: Error, LocalizedError {
    let status: Int32
    let native: Int32
    var errorDescription: String? {
        "原生 MTP USB 请求失败（\(status)/\(native)）。请完整退出 OpenMTP／预览等客户端，保持 sphaira MTP Install 模式；必要时手动重连。不会停止系统服务或自动重试。"
    }
}

actor LibUSBSphairaLink: SphairaUSBLink {
    private final class Handle: @unchecked Sendable {
        var pointer: OpaquePointer?
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        func close() -> Int32 {
            guard let pointer else { return 0 }
            self.pointer = nil
            return ss_sphaira_usb_close(pointer)
        }
        deinit { _ = close() }
    }
    let packetSize: Int
    private let handle: Handle
    init() throws {
        var pointer: OpaquePointer?
        var packet: UInt16 = 0
        var native: Int32 = 0
        let status = ss_sphaira_usb_open(&pointer, &packet, &native)
        guard status == 0, let pointer else { throw SphairaNativeError(status: status, native: native) }
        handle = Handle(pointer); packetSize = Int(packet)
    }
    func write(_ bytes: Data) throws {
        try Task.checkCancellation()
        guard let pointer = handle.pointer else { throw SphairaUploadError.invalidResponse }
        var native: Int32 = 0
        let status = bytes.withUnsafeBytes { buffer in
            ss_sphaira_usb_write(pointer, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count, &native)
        }
        guard status == 0 else { throw SphairaNativeError(status: status, native: native) }
    }
    func read() throws -> Data {
        try Task.checkCancellation()
        guard let pointer = handle.pointer else { throw SphairaUploadError.invalidResponse }
        var data = Data(count: 65536)
        var received = 0
        var native: Int32 = 0
        let status = data.withUnsafeMutableBytes { buffer in
            ss_sphaira_usb_read(pointer, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &received, &native)
        }
        guard status == 0 else { throw SphairaNativeError(status: status, native: native) }
        data.count = received
        return data
    }
    func close() throws {
        let status = handle.close()
        guard status == 0 else { throw SphairaNativeError(status: 7, native: status) }
    }
}

/// Raw USB adapter: one data phase, bounded packet-aligned writes, final short packet/ZLP.
/// Installed only in the direct child helper. Inventory remains on ImageCaptureCore.
actor NativeSphairaMTP: SphairaUploadTransport {
    private let link: any SphairaUSBLink
    private var input = Data()
    private var output = Data()
    private var transaction: UInt32 = 0
    private var operation: SphairaUploadCodec.Operation?
    private var commandTransaction: UInt32 = 0
    private var storage: UInt32?
    private var fileSize: UInt64 = 0
    private var payloadExpected: UInt64 = 0
    private var payloadReceived: UInt64 = 0
    private var dataActive = false
    private var dataEnded = false
    private var created = false
    private var fileComplete = false
    private var inspected = false
    init(link: any SphairaUSBLink) { self.link = link }

    func inspectSession() async throws -> SphairaUploadSession {
        guard !inspected, [64, 512, 1024].contains(link.packetSize) else { throw SphairaUploadError.unsupportedSession }
        inspected = true
        let info = try SphairaDeviceInfo.decode(await exchange(0x1001, [], transaction: 0, data: true))
        _ = try await exchange(0x1002, [1], transaction: 0, data: false)
        transaction = 1
        let identifiers = try PTPCodec.identifiers(await exchange(0x1004, [], transaction: transaction, data: true))
        guard identifiers.count <= 64 else { throw SphairaUploadError.unsupportedSession }
        var stores: [MTPStorage] = []
        for id in identifiers {
            transaction += 1
            stores.append(try PTPCodec.storage(await exchange(0x1005, [id], transaction: transaction, data: true), id: id))
        }
        let session = SphairaUploadSession(deviceVersion: info.version, supportedOperations: info.operations,
                                           storages: stores, lastTransaction: transaction)
        storage = try session.installStorage()
        return session
    }

    func sendCommand(_ container: Data) async throws {
        guard storage != nil, !fileComplete, operation == nil, container.count >= 12,
              Self.u32(container, 0) == container.count, Self.u16(container, 4) == 1,
              let next = SphairaUploadCodec.Operation(rawValue: Self.u16(container, 6)),
              Self.u32(container, 8) == transaction + 1 else { throw SphairaUploadError.invalidDataset }
        if next == .sendObjectPropList {
            guard !created, container.count == 32, Self.u32(container, 12) == storage,
                  Self.u32(container, 16) == .max, Self.u32(container, 20) == 0x3000 else {
                throw SphairaUploadError.invalidDataset
            }
            fileSize = UInt64(Self.u32(container, 24)) << 32 | UInt64(Self.u32(container, 28))
            guard fileSize > 0, fileSize <= UInt64(Int64.max) else { throw SphairaUploadError.invalidDataset }
        } else {
            guard created, container.count == 12 else { throw SphairaUploadError.invalidDataset }
        }
        operation = next; transaction += 1; commandTransaction = transaction
        dataEnded = false
        try await link.write(container)
    }

    func beginData(_ header: Data) throws {
        guard let operation, !dataActive, !dataEnded, header.count == 12, Self.u16(header, 4) == 2,
              Self.u16(header, 6) == operation.rawValue, Self.u32(header, 8) == commandTransaction else {
            throw SphairaUploadError.invalidDataset
        }
        let length = Self.u32(header, 0)
        if operation == .sendObject {
            payloadExpected = fileSize
            guard length == UInt32(min(fileSize + 12, UInt64(UInt32.max))) else { throw SphairaUploadError.invalidDataset }
        } else {
            guard (13...1024).contains(length) else { throw SphairaUploadError.invalidDataset }
            payloadExpected = UInt64(length - 12)
        }
        output = header; payloadReceived = 0; dataActive = true
    }

    func writeData(_ bytes: Data) async throws {
        guard dataActive, bytes.count <= 4 * 1024 * 1024,
              UInt64(bytes.count) <= payloadExpected - payloadReceived else { throw SphairaUploadError.invalidDataset }
        payloadReceived += UInt64(bytes.count)
        output.append(bytes)
        // A standalone 12-byte header would prematurely terminate the USB data phase.
        // Never emit a short packet until endData, including between source chunks.
        let count = output.count / link.packetSize * link.packetSize
        if count > 0 {
            // Leave no >4 MiB native call even when the pending header adds bytes.
            var remaining = count
            while remaining > 0 {
                let size = min(remaining, 1024 * 1024)
                try await link.write(Data(output.prefix(size)))
                output.removeFirst(size); remaining -= size
            }
        }
    }

    func endData() async throws {
        guard dataActive, payloadReceived == payloadExpected else { throw SphairaUploadError.invalidDataset }
        // Empty final buffer means total header+payload is packet aligned: emit a ZLP.
        try await link.write(output)
        output.removeAll(keepingCapacity: true); dataActive = false; dataEnded = true
    }

    func receiveResponse() async throws -> Data {
        guard let operation, dataEnded, !dataActive else { throw SphairaUploadError.invalidResponse }
        let response = try await readContainer(limit: 32)
        _ = try SphairaUploadCodec.response(response, transaction: commandTransaction,
                                           parameters: operation == .sendObjectPropList ? 3 : 0)
        if operation == .sendObjectPropList { created = true }
        else { fileComplete = true }
        self.operation = nil
        return response
    }

    func close() async throws {
        // Never inject CloseSession into a possibly unfinished SendObject phase.
        // Physical close/process exit releases host ownership, not device install state.
        try await link.close()
    }

    private func exchange(_ code: UInt16, _ parameters: [UInt32], transaction: UInt32, data: Bool) async throws -> Data {
        var command = Data()
        PTPCodec.append(UInt32(12 + parameters.count * 4), to: &command)
        PTPCodec.append(UInt16(1), to: &command); PTPCodec.append(code, to: &command)
        PTPCodec.append(transaction, to: &command)
        for parameter in parameters { PTPCodec.append(parameter, to: &command) }
        try await link.write(command)
        let first = try await readContainer(limit: 65536)
        if Self.u16(first, 4) == 3 {
            _ = try SphairaUploadCodec.response(first, transaction: transaction, parameters: 0)
            guard !data else { throw SphairaUploadError.invalidResponse }
            return Data()
        }
        guard data, Self.u16(first, 4) == 2, Self.u16(first, 6) == code,
              Self.u32(first, 8) == transaction else { throw SphairaUploadError.invalidResponse }
        _ = try SphairaUploadCodec.response(await readContainer(limit: 32), transaction: transaction, parameters: 0)
        return Data(first.dropFirst(12))
    }

    private func readContainer(limit: Int) async throws -> Data {
        while input.count < 12 { try await fillInput() }
        let length = Int(Self.u32(input, 0))
        guard length >= 12, length <= limit else { throw SphairaUploadError.invalidResponse }
        while input.count < length { try await fillInput() }
        let result = Data(input.prefix(length)); input.removeFirst(length)
        return result
    }
    private func fillInput() async throws {
        let bytes = try await link.read()
        guard !bytes.isEmpty, bytes.count <= 65536, input.count + bytes.count <= 131072 else {
            throw SphairaUploadError.invalidResponse
        }
        input.append(bytes)
    }
    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let index = data.startIndex + offset
        return UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }
}

struct SphairaDeviceInfo {
    let version: String
    let operations: Set<UInt16>
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65536 else { throw SphairaUploadError.invalidResponse }
        var cursor = Cursor(data: Array(data))
        _ = try cursor.number(2); _ = try cursor.number(4); _ = try cursor.number(2)
        _ = try cursor.string(); _ = try cursor.number(2)
        let operations = try cursor.array()
        for _ in 0..<4 { _ = try cursor.array() }
        _ = try cursor.string(); _ = try cursor.string()
        let version = try cursor.string()
        _ = try cursor.string() // Serial parsed only for dataset integrity; never retained.
        guard cursor.offset == data.count else { throw SphairaUploadError.invalidResponse }
        return .init(version: version, operations: Set(operations))
    }
    private struct Cursor {
        let data: [UInt8]
        var offset = 0
        mutating func number(_ width: Int) throws -> UInt32 {
            guard offset + width <= data.count else { throw SphairaUploadError.invalidResponse }
            let value = (0..<width).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
            offset += width; return value
        }
        mutating func array() throws -> [UInt16] {
            let count = try number(4)
            guard count <= 4096 else { throw SphairaUploadError.invalidResponse }
            return try (0..<count).map { _ in UInt16(try number(2)) }
        }
        mutating func string() throws -> String {
            let count = Int(try number(1))
            if count == 0 { return "" }
            var bytes = Data()
            for _ in 0..<count { PTPCodec.append(UInt16(try number(2)), to: &bytes) }
            guard bytes.suffix(2) == Data([0, 0]),
                  let string = String(data: bytes.dropLast(2), encoding: .utf16LittleEndian),
                  !string.contains("\0") else { throw SphairaUploadError.invalidResponse }
            return string
        }
    }
}
