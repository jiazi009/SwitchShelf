import Foundation

struct MTPFileStoreRecord: Sendable {
    let handle: UInt32
    var value: MTPFileStorage
}
struct MTPFileObjectRecord: Sendable {
    let handle: UInt32
    let storage: UInt32
    let parent: UInt32
    let name: String
    let isDirectory: Bool
    let byteCount: UInt64?
    let modifiedDate: String?
}
protocol MTPFileTransport: Sendable {
    func open() async throws
    func storages() async throws -> [MTPFileStoreRecord]
    func children(storage: UInt32, parent: UInt32) async throws -> [UInt32]
    func object(_ handle: UInt32) async throws -> MTPFileObjectRecord
    func download(_ handle: UInt32, expectedBytes: UInt64,
                  consume: @escaping @Sendable (Data) async throws -> Void) async throws -> UInt64
    func upload(storage: UInt32, parent: UInt32, name: String, byteCount: UInt64,
                source: @escaping @Sendable (UInt64, Int) async throws -> Data,
                progress: @escaping @Sendable (UInt64) async -> Void) async throws -> UInt64
    func close() async throws
}

/// Explicit file operations are separate from inventory and installation. This
/// transport has no delete, overwrite, folder creation, format, retry or resume.
actor MTPFileUSBTransport: MTPFileTransport {
    private enum Operation: UInt16 {
        case open = 0x1002, close = 0x1003, storages = 0x1004, storageInfo = 0x1005
        case children = 0x1007, objectInfo = 0x1008, getObject = 0x1009
        case sendObjectInfo = 0x100c, sendObject = 0x100d
    }
    private let link: any SphairaUSBLink
    private var input = Data()
    private var transaction: UInt32 = 0
    private var opened = false
    private var closed = false
    private var busy = false
    private var frameActive = false
    private var poisoned = false
    static let maximumFileBytes = UInt64(UInt32.max) - 12
    init(link: any SphairaUSBLink) { self.link = link }

    func open() async throws {
        guard !opened, !closed, [64, 512, 1024].contains(link.packetSize) else { throw MTPFileError.invalidResponse }
        _ = try await metadata(.open, [1], maximum: 32, expectsData: false, transaction: 0)
        opened = true
    }
    func storages() async throws -> [MTPFileStoreRecord] {
        let ids = try PTPCodec.identifiers(await request(.storages, [], maximum: 12 + 4 + 64 * 4))
        guard ids.count <= 64, Set(ids).count == ids.count else { throw MTPFileError.invalidMetadata }
        var result: [MTPFileStoreRecord] = []
        for id in ids {
            let data = try await request(.storageInfo, [id], maximum: 12 + 2048)
            result.append(try MTPFileDataset.storage(data, handle: id))
        }
        return result
    }
    func children(storage: UInt32, parent: UInt32) async throws -> [UInt32] {
        try PTPCodec.identifiers(await request(.children, [storage, 0, parent], maximum: 400_016))
    }
    func object(_ handle: UInt32) async throws -> MTPFileObjectRecord {
        try MTPFileDataset.object(await request(.objectInfo, [handle], maximum: 12 + 4096), handle: handle)
    }
    private func nextTransaction() throws -> UInt32 {
        guard opened, !closed, !poisoned, !busy, transaction < UInt32.max else { throw MTPFileError.invalidResponse }
        transaction += 1
        return transaction
    }
    private func request(_ operation: Operation, _ parameters: [UInt32], maximum: Int) async throws -> Data {
        try await metadata(operation, parameters, maximum: maximum, expectsData: true, transaction: nextTransaction())
    }
    private func metadata(_ operation: Operation, _ parameters: [UInt32], maximum: Int,
                          expectsData: Bool, transaction: UInt32) async throws -> Data {
        guard !closed, !poisoned, !busy else { throw MTPFileError.invalidResponse }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            frameActive = true
            try await link.write(command(operation, parameters, transaction: transaction))
            let first = try await readContainer(maximum: maximum)
            if NativeSphairaMTP.u16(first, 4) == 3 {
                _ = try response(first, transaction: transaction, parameterCount: 0)
                guard !expectsData else { throw MTPFileError.invalidResponse }
                return Data()
            }
            guard expectsData, NativeSphairaMTP.u16(first, 4) == 2,
                  NativeSphairaMTP.u16(first, 6) == operation.rawValue,
                  NativeSphairaMTP.u32(first, 8) == transaction else { throw MTPFileError.invalidResponse }
            _ = try response(await readContainer(maximum: 32), transaction: transaction, parameterCount: 0)
            return Data(first.dropFirst(12))
        } catch {
            if frameActive { poisoned = true }
            throw error
        }
    }
    func download(_ handle: UInt32, expectedBytes: UInt64,
                  consume: @escaping @Sendable (Data) async throws -> Void) async throws -> UInt64 {
        guard expectedBytes <= Self.maximumFileBytes else { throw MTPFileError.resourceLimit }
        let tx = try nextTransaction()
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            frameActive = true
            try await link.write(command(.getObject, [handle], transaction: tx))
            let header = try await take(12)
            if NativeSphairaMTP.u16(header, 4) == 3 {
                _ = try response(header, transaction: tx, parameterCount: 0)
                throw MTPFileError.invalidResponse
            }
            guard NativeSphairaMTP.u32(header, 0) == expectedBytes + 12,
                  NativeSphairaMTP.u16(header, 4) == 2,
                  NativeSphairaMTP.u16(header, 6) == Operation.getObject.rawValue,
                  NativeSphairaMTP.u32(header, 8) == tx else { throw MTPFileError.incompleteTransfer }
            var count: UInt64 = 0
            while count < expectedBytes {
                try Task.checkCancellation()
                let chunk = try await take(Int(min(65_536, expectedBytes - count)))
                try await consume(chunk)
                count += UInt64(chunk.count)
            }
            _ = try response(await readContainer(maximum: 32), transaction: tx, parameterCount: 0)
            return count
        } catch {
            if frameActive { poisoned = true }
            throw error
        }
    }
    func upload(storage: UInt32, parent: UInt32, name: String, byteCount: UInt64,
                source: @escaping @Sendable (UInt64, Int) async throws -> Data,
                progress: @escaping @Sendable (UInt64) async -> Void) async throws -> UInt64 {
        guard byteCount <= Self.maximumFileBytes, MTPFileNames.isValid(name) else { throw MTPFileError.resourceLimit }
        let info = try MTPFileDataset.objectInfo(storage: storage, parent: parent, name: name, byteCount: byteCount)
        let infoTX = try nextTransaction()
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            frameActive = true
            try await link.write(command(.sendObjectInfo, [storage, parent], transaction: infoTX))
            try await writeData(.sendObjectInfo, transaction: infoTX, byteCount: UInt64(info.count), source: { offset, count in
                Data(info[Int(offset)..<(Int(offset) + count)])
            }, progress: { _ in })
            let created = try response(await readContainer(maximum: 32), transaction: infoTX, parameterCount: 3)
            guard created[0] == storage, created[2] != 0, created[2] != UInt32.max,
                  created[1] == parent || (parent == UInt32.max && [UInt32(0), storage].contains(created[1])) else { throw MTPFileError.invalidResponse }
            guard transaction < UInt32.max else { throw MTPFileError.invalidResponse }
            transaction += 1
            let dataTX = transaction
            try Task.checkCancellation()
            frameActive = true
            try await link.write(command(.sendObject, [], transaction: dataTX))
            try await writeData(.sendObject, transaction: dataTX, byteCount: byteCount, source: source, progress: progress)
            _ = try response(await readContainer(maximum: 32), transaction: dataTX, parameterCount: 0)
            return byteCount
        } catch {
            if frameActive { poisoned = true }
            throw error
        }
    }
    private func writeData(_ operation: Operation, transaction: UInt32, byteCount: UInt64,
                           source: @escaping @Sendable (UInt64, Int) async throws -> Data,
                           progress: @escaping @Sendable (UInt64) async -> Void) async throws {
        var pending = MTPFileDataset.header(length: UInt32(byteCount + 12), type: 2,
                                           code: operation.rawValue, transaction: transaction)
        var offset: UInt64 = 0
        while offset < byteCount {
            try Task.checkCancellation()
            let count = Int(min(1_048_576, byteCount - offset))
            let bytes = try await source(offset, count)
            guard bytes.count == count else { throw MTPFileError.sourceChanged }
            pending.append(bytes)
            let complete = pending.count / link.packetSize * link.packetSize
            if complete > 0 {
                // Header and source bytes share packet-aligned writes. A standalone
                // 12-byte header would prematurely end the MTP data phase.
                var sent = 0
                while sent < complete {
                    let amount = min(1_048_576, complete - sent)
                    try await link.write(Data(pending[sent..<(sent + amount)]))
                    sent += amount
                }
                pending.removeFirst(complete)
            }
            offset += UInt64(bytes.count)
            await progress(offset)
        }
        try Task.checkCancellation()
        // An empty final chunk deliberately emits a ZLP for an aligned phase.
        try await link.write(pending)
    }
    private func command(_ operation: Operation, _ parameters: [UInt32], transaction: UInt32) -> Data {
        var data = MTPFileDataset.header(length: UInt32(12 + parameters.count * 4), type: 1,
                                         code: operation.rawValue, transaction: transaction)
        for parameter in parameters { PTPCodec.append(parameter, to: &data) }
        return data
    }
    private func response(_ data: Data, transaction: UInt32, parameterCount: Int) throws -> [UInt32] {
        guard data.count >= 12, data.count <= 32, data.count.isMultiple(of: 4),
              NativeSphairaMTP.u32(data, 0) == data.count,
              NativeSphairaMTP.u16(data, 4) == 3,
              NativeSphairaMTP.u32(data, 8) == transaction else { throw MTPFileError.invalidResponse }
        let code = NativeSphairaMTP.u16(data, 6)
        frameActive = false
        guard code == 0x2001 else { throw MTPFileError.response(code) }
        guard data.count == 12 + parameterCount * 4 else { poisoned = true; throw MTPFileError.invalidResponse }
        return (0..<parameterCount).map { NativeSphairaMTP.u32(data, 12 + $0 * 4) }
    }
    private func take(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 400_016 else { throw MTPFileError.resourceLimit }
        var emptyPackets = 0
        while input.count < count {
            try Task.checkCancellation()
            let bytes = try await link.read()
            if bytes.isEmpty {
                emptyPackets += 1
                guard emptyPackets <= 4 else { throw MTPFileError.invalidResponse }
                continue // A USB ZLP may terminate an aligned data phase.
            }
            emptyPackets = 0
            guard bytes.count <= 65_536, input.count + bytes.count <= 465_552 else { throw MTPFileError.invalidResponse }
            input.append(bytes)
        }
        let result = Data(input.prefix(count)); input.removeFirst(count)
        return result
    }
    private func readContainer(maximum: Int) async throws -> Data {
        let header = try await take(12)
        let length = Int(NativeSphairaMTP.u32(header, 0))
        guard length >= 12, length <= maximum else { throw MTPFileError.invalidResponse }
        let payload = try await take(length - 12)
        return header + payload
    }
    func close() async throws {
        guard !closed, !busy else { throw MTPFileError.invalidResponse }
        var closeError: (any Error)?
        if opened, !poisoned, !frameActive, !Task.isCancelled, transaction < UInt32.max {
            transaction += 1
            do { _ = try await metadata(.close, [], maximum: 32, expectsData: false, transaction: transaction) }
            catch { closeError = error }
        }
        closed = true
        do { try await link.close() } catch { throw error }
        if let closeError { throw closeError }
    }
}

enum MTPFileDataset {
    static func header(length: UInt32, type: UInt16, code: UInt16, transaction: UInt32) -> Data {
        var data = Data()
        PTPCodec.append(length, to: &data); PTPCodec.append(type, to: &data)
        PTPCodec.append(code, to: &data); PTPCodec.append(transaction, to: &data)
        return data
    }
    static func storage(_ data: Data, handle: UInt32) throws -> MTPFileStoreRecord {
        var cursor = Cursor(data)
        _ = try cursor.number(2); _ = try cursor.number(2)
        let access = try cursor.number(2)
        let capacity = try cursor.number(8); let free = try cursor.number(8)
        _ = try cursor.number(4)
        let name = try cursor.string(); _ = try cursor.string()
        guard cursor.atEnd, !name.isEmpty, name.utf16.count <= 254, access <= 2 else { throw MTPFileError.invalidMetadata }
        let canUpload = MTPFileNames.isWritableSD(name) && access == 0
        let role = canUpload ? "SD 卡文件，可上传" : MTPFileNames.isWritableSD(name) ? "SD 卡文件，只读" : "设备虚拟入口，只读"
        return MTPFileStoreRecord(handle: handle, value: .init(name: name,
            capacityBytes: capacity == UInt64.max ? nil : capacity, freeBytes: free == UInt64.max ? nil : free,
            canUpload: canUpload, isReadOnly: !canUpload, role: role))
    }
    static func object(_ data: Data, handle: UInt32) throws -> MTPFileObjectRecord {
        var cursor = Cursor(data)
        let storage = UInt32(try cursor.number(4)); let format = try cursor.number(2)
        _ = try cursor.number(2); let size = try cursor.number(4)
        try cursor.skip(26); let parent = UInt32(try cursor.number(4)); try cursor.skip(10)
        let name = try cursor.string(); _ = try cursor.string()
        let modified = try cursor.string(); _ = try cursor.string()
        guard cursor.atEnd, MTPFileNames.isValid(name) else { throw MTPFileError.invalidMetadata }
        return .init(handle: handle, storage: storage, parent: parent, name: name,
                     isDirectory: format == 0x3001, byteCount: size == UInt32.max ? nil : size,
                     modifiedDate: modified.isEmpty ? nil : modified)
    }
    static func objectInfo(storage: UInt32, parent: UInt32, name: String, byteCount: UInt64) throws -> Data {
        guard byteCount <= MTPFileUSBTransport.maximumFileBytes, MTPFileNames.isValid(name) else { throw MTPFileError.invalidRequest }
        var data = Data()
        PTPCodec.append(storage, to: &data); PTPCodec.append(UInt16(0x3000), to: &data)
        PTPCodec.append(UInt16(0), to: &data); PTPCodec.append(UInt32(byteCount), to: &data)
        data.append(Data(count: 26)); PTPCodec.append(parent, to: &data)
        data.append(Data(count: 10)); data.append(try string(name)); data.append(Data([0, 0, 0]))
        return data
    }
    static func string(_ value: String) throws -> Data {
        guard value.utf16.count <= 254, !value.contains("\0") else { throw MTPFileError.invalidMetadata }
        var data = Data([UInt8(value.utf16.count + 1)])
        for unit in value.utf16 { PTPCodec.append(unit, to: &data) }
        PTPCodec.append(UInt16(0), to: &data)
        return data
    }
    struct Cursor {
        let bytes: [UInt8]
        var offset = 0
        init(_ data: Data) { bytes = Array(data) }
        var atEnd: Bool { offset == bytes.count }
        mutating func number(_ width: Int) throws -> UInt64 {
            guard width > 0, width <= 8, width <= bytes.count - offset else { throw MTPFileError.invalidMetadata }
            let value = (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
            offset += width
            return value
        }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= bytes.count - offset else { throw MTPFileError.invalidMetadata }
            offset += count
        }
        mutating func string() throws -> String {
            let count = Int(try number(1))
            if count == 0 { return "" }
            var units: [UInt16] = []
            for _ in 0..<count { units.append(UInt16(try number(2))) }
            guard units.last == 0 else { throw MTPFileError.invalidMetadata }
            units.removeLast()
            var data = Data()
            for value in units { PTPCodec.append(value, to: &data) }
            guard let result = String(data: data, encoding: .utf16LittleEndian), !result.contains("\0") else { throw MTPFileError.invalidMetadata }
            return result
        }
    }
}
