import Foundation

/// An explicitly selected, metadata-only PTP session over the existing libusb link.
/// The caller must hold DeviceLease until close or process exit has been verified.
actor LibUSBInventoryTransport: InventoryTransport {
    private enum Operation: UInt16 {
        case open = 0x1002, close = 0x1003, storageIDs = 0x1004
        case storageInfo = 0x1005, handles = 0x1007, objectInfo = 0x1008
    }
    private let link: any SphairaUSBLink
    private var input = Data()
    private var transaction: UInt32 = 0
    private var opened = false
    private var poisoned = false
    private var busy = false
    private var closed = false
    private let maxContainer = 400_016

    init(link: any SphairaUSBLink) { self.link = link }

    static func connect() async throws -> LibUSBInventoryTransport {
        let link: LibUSBSphairaLink
        do { link = try LibUSBSphairaLink() }
        catch let error as SphairaNativeError {
            let code: DeviceServiceError.Code
            switch error.status {
            case 1: code = .runtimeMissing
            case 2: code = .runtimeIncompatible
            case 3: code = .busy
            case 4: code = .noDevice
            case 5: code = .multipleDevices
            case 6: code = .accessDeniedOrBusy
            default: code = .transport
            }
            throw DeviceServiceError(code: code, message: "libusb 无法打开 Switch MTP 接口；请确认 MTP 模式并退出其他客户端。系统服务不会被停止或重置。", nativeCode: Int(error.native))
        }
        return try await connect(link: link)
    }

    static func connect(link: any SphairaUSBLink) async throws -> LibUSBInventoryTransport {
        let transport = LibUSBInventoryTransport(link: link)
        do { try await transport.open(); return transport }
        catch {
            do { try await transport.close() }
            catch { throw DeviceServiceError(code: .transport, message: "libusb 会话打开失败且释放未确认；请检查设备后再重试。") }
            throw error
        }
    }

    private func open() async throws {
        guard !opened, !closed else { throw invalid() }
        _ = try await exchange(.open, [1], tx: 0, expectsData: false)
        opened = true
    }
    func storages() async throws -> [MTPStorage] {
        do {
            let ids = try PTPCodec.identifiers(await request(.storageIDs, []))
            guard ids.count <= 64 else { throw invalid() }
            var result: [MTPStorage] = []
            for id in ids { result.append(try PTPCodec.storage(await request(.storageInfo, [id]), id: id)) }
            return result
        } catch { poisoned = true; throw error }
    }
    func children(storage: UInt32, parent: UInt32) async throws -> [UInt32] {
        do { return try PTPCodec.identifiers(await request(.handles, [storage, 0, parent])) }
        catch { poisoned = true; throw error }
    }
    func object(id: UInt32) async throws -> MTPObject {
        do { return try PTPCodec.object(await request(.objectInfo, [id]), id: id) }
        catch { poisoned = true; throw error }
    }
    private func request(_ op: Operation, _ parameters: [UInt32]) async throws -> Data {
        guard opened, !closed, !poisoned, !busy, transaction < UInt32.max else { throw invalid() }
        transaction += 1
        return try await exchange(op, parameters, tx: transaction, expectsData: true)
    }
    private func exchange(_ op: Operation, _ parameters: [UInt32], tx: UInt32, expectsData: Bool) async throws -> Data {
        guard !busy, !closed else { throw invalid() }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            var command = Data()
            PTPCodec.append(UInt32(12 + 4 * parameters.count), to: &command)
            PTPCodec.append(UInt16(1), to: &command)
            PTPCodec.append(op.rawValue, to: &command)
            PTPCodec.append(tx, to: &command)
            for parameter in parameters { PTPCodec.append(parameter, to: &command) }
            try await link.write(command)
            let limit: Int
            switch op {
            case .open, .close: limit = 32
            case .storageIDs: limit = 12 + 4 + 64 * 4
            case .storageInfo: limit = 12 + 2048
            case .handles: limit = maxContainer
            case .objectInfo: limit = 12 + 4096
            }
            let first = try await readContainer(limit: limit)
            if NativeSphairaMTP.u16(first, 4) == 3 {
                try validateResponse(first, transaction: tx)
                guard !expectsData else { throw invalid() }
                return Data()
            }
            guard expectsData, NativeSphairaMTP.u16(first, 4) == 2,
                  NativeSphairaMTP.u16(first, 6) == op.rawValue,
                  NativeSphairaMTP.u32(first, 8) == tx else { throw invalid() }
            try validateResponse(await readContainer(limit: 32), transaction: tx)
            return Data(first.dropFirst(12))
        } catch let error as SphairaNativeError {
            poisoned = true
            throw DeviceServiceError(code: .transport, message: "libusb MTP 元数据请求失败；清单覆盖范围未知。", nativeCode: Int(error.native))
        } catch { poisoned = true; throw error }
    }
    private func validateResponse(_ data: Data, transaction: UInt32) throws {
        guard data.count == 12, NativeSphairaMTP.u32(data, 8) == transaction else { throw invalid() }
        try PTPCodec.validateResponse(data)
    }
    private func readContainer(limit: Int) async throws -> Data {
        while input.count < 12 { try await fill() }
        let length = Int(NativeSphairaMTP.u32(input, 0))
        guard length >= 12, length <= limit else { throw invalid() }
        while input.count < length { try await fill() }
        let result = Data(input.prefix(length))
        input.removeFirst(length)
        return result
    }
    private func fill() async throws {
        let chunk = try await link.read()
        guard !chunk.isEmpty, chunk.count <= 65_536, input.count + chunk.count <= maxContainer + 65_536 else { throw invalid() }
        input.append(chunk)
    }
    func close() async throws {
        guard !closed, !busy else { throw invalid() }
        var sessionError: (any Error)?
        if opened && !poisoned && transaction < UInt32.max {
            transaction += 1
            do { _ = try await exchange(.close, [], tx: transaction, expectsData: false) }
            catch { sessionError = error }
        }
        closed = true
        do { try await link.close() }
        catch { throw error }
        if let sessionError { throw sessionError }
    }
    private func invalid() -> DeviceServiceError {
        DeviceServiceError(code: .invalidMetadata, message: "libusb MTP 响应无效或会话状态不安全；清单覆盖范围未知。")
    }
}
