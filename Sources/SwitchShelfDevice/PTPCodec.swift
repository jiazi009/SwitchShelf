import Foundation

/// Strict, bounded PTP datasets. No GetObject/SendObject/Delete/Format operation is allowed.
enum PTPCodec {
    static func command(_ operation: UInt16, parameters: [UInt32], transaction: UInt32) throws -> Data {
        let expectedCounts: [UInt16: Int] = [0x1004: 0, 0x1005: 1, 0x1007: 3, 0x1008: 1]
        guard expectedCounts[operation] == parameters.count else {
            throw invalid("PTP operation is not on the metadata-only allowlist.")
        }
        var data = Data()
        append(UInt32(12 + parameters.count * 4), to: &data)
        append(UInt16(1), to: &data); append(operation, to: &data); append(transaction, to: &data)
        for parameter in parameters { append(parameter, to: &data) }
        return data
    }
    static func validateResponse(_ data: Data) throws {
        guard (12...32).contains(data.count) else { throw invalid("Invalid PTP response length.") }
        var cursor = Cursor(data)
        let length = try cursor.u32()
        let type = try cursor.u16()
        let code = try cursor.u16()
        _ = try cursor.u32()
        // ImageCaptureCore reassigns transaction IDs; only one request may be in flight.
        guard length == data.count, data.count >= 12, data.count <= 32,
              data.count % 4 == 0, type == 3 else { throw invalid("Malformed PTP response container.") }
        guard code == 0x2001 else {
            throw DeviceServiceError(code: [UInt16(0x200f), 0x2019].contains(code) ? .accessDeniedOrBusy : .transport,
                message: "PTP metadata command failed; inventory coverage is unknown.", nativeCode: Int(code))
        }
    }
    static func identifiers(_ data: Data) throws -> [UInt32] {
        guard data.count <= 400_004 else { throw invalid("PTP handle array exceeds the safety limit.") }
        var cursor = Cursor(data)
        let count = Int(try cursor.u32())
        guard count <= 100_000, data.count == 4 + count * 4 else { throw invalid("Invalid PTP handle array length/count.") }
        return try (0..<count).map { _ in try cursor.u32() }
    }
    static func storage(_ data: Data, id: UInt32) throws -> MTPStorage {
        guard data.count <= 2048 else { throw invalid("PTP storage dataset exceeds the safety limit.") }
        var cursor = Cursor(data)
        try cursor.skip(26) // StorageType, FilesystemType, Access, capacities and free-object count.
        let name = try cursor.string()
        _ = try cursor.string() // Volume label: deliberately not retained/logged.
        guard cursor.isAtEnd, !name.isEmpty else { throw invalid("Invalid PTP storage dataset.") }
        return MTPStorage(id: id, name: name)
    }
    static func object(_ data: Data, id: UInt32) throws -> MTPObject {
        guard data.count <= 4096 else { throw invalid("PTP object dataset exceeds the safety limit.") }
        var cursor = Cursor(data)
        let storage = try cursor.u32()
        let format = try cursor.u16()
        try cursor.skip(32)
        let parent = try cursor.u32()
        try cursor.skip(10)
        let name = try cursor.string()
        for _ in 0..<3 { _ = try cursor.string() } // CaptureDate, ModificationDate, Keywords.
        guard cursor.isAtEnd else { throw invalid("Unexpected PTP object dataset bytes.") }
        return MTPObject(id: id, parentID: parent, storageID: storage, name: name, isFolder: format == 0x3001)
    }
    static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private static func invalid(_ message: String) -> DeviceServiceError {
        DeviceServiceError(code: .invalidMetadata, message: message)
    }
    private struct Cursor {
        let data: [UInt8]
        var offset = 0
        init(_ data: Data) { self.data = Array(data) }
        var isAtEnd: Bool { offset == data.count }
        mutating func skip(_ count: Int) throws {
            guard count >= 0, count <= data.count - offset else { throw PTPCodec.invalid("Truncated PTP dataset.") }
            offset += count
        }
        mutating func u16() throws -> UInt16 { UInt16(try integer(bytes: 2)) }
        mutating func u32() throws -> UInt32 { UInt32(try integer(bytes: 4)) }
        mutating func integer(bytes: Int) throws -> UInt64 {
            guard bytes <= data.count - offset else { throw PTPCodec.invalid("Truncated PTP integer.") }
            var value: UInt64 = 0
            for index in 0..<bytes { value |= UInt64(data[offset + index]) << (8 * index) }
            offset += bytes
            return value
        }
        mutating func string() throws -> String {
            let count = Int(try integer(bytes: 1))
            if count == 0 { return "" }
            guard count * 2 <= data.count - offset else { throw PTPCodec.invalid("Truncated PTP UTF-16 string.") }
            var units: [UInt16] = []
            for _ in 0..<count { units.append(try u16()) }
            guard units.last == 0 else { throw PTPCodec.invalid("PTP string lacks its required terminator.") }
            units.removeLast()
            var bytes = Data()
            for unit in units { PTPCodec.append(unit, to: &bytes) }
            guard let value = String(data: bytes, encoding: .utf16LittleEndian), !value.contains("\0") else {
                throw PTPCodec.invalid("Invalid PTP UTF-16 string.")
            }
            return value
        }
    }
}
