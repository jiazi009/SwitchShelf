import Foundation

/// Separate from PTPCodec: inventory's metadata-only operation allowlist stays unchanged.
/// Pinned reference: libhaze f1c9c632b5c615eabfb29a0dab89fedf606588e4.
enum SphairaUploadCodec {
    enum Operation: UInt16 { case sendObjectPropList = 0x9808, sendObject = 0x100d }
    static let rootParent = UInt32.max
    static let undefinedFormat: UInt32 = 0x3000

    static func command(_ operation: Operation, parameters: [UInt32], transaction: UInt32) throws -> Data {
        guard transaction != 0,
              parameters.count == (operation == .sendObjectPropList ? 5 : 0) else {
            throw SphairaUploadError.invalidDataset
        }
        var data = header(length: UInt32(12 + parameters.count * 4), type: 1,
                          code: operation.rawValue, transaction: transaction)
        for parameter in parameters { PTPCodec.append(parameter, to: &data) }
        return data
    }

    static func dataHeader(_ operation: Operation, payloadBytes: UInt64, transaction: UInt32) throws -> Data {
        guard transaction != 0, payloadBytes <= UInt64.max - 12 else { throw SphairaUploadError.invalidDataset }
        // The property-list command carries the authoritative 64-bit size. libhaze uses it
        // instead of this saturated 32-bit USB container length for SendObject.
        return header(length: UInt32(min(payloadBytes + 12, UInt64(UInt32.max))), type: 2,
                      code: operation.rawValue, transaction: transaction)
    }

    static func propertyParameters(storage: UInt32, byteCount: UInt64) throws -> [UInt32] {
        guard storage != 0, storage != UInt32.max, byteCount > 0, byteCount <= UInt64(Int64.max) else {
            throw SphairaUploadError.invalidDataset
        }
        return [storage, rootParent, undefinedFormat, UInt32(byteCount >> 32), UInt32(truncatingIfNeeded: byteCount)]
    }

    static func filenameProperty(_ name: String) throws -> Data {
        guard SphairaPackageName.isValid(name) else { throw SphairaUploadError.invalidDataset }
        var data = Data()
        PTPCodec.append(UInt32(1), to: &data) // One property, not an ObjectInfo dataset.
        PTPCodec.append(UInt32(0), to: &data) // New object: no existing handle.
        PTPCodec.append(UInt16(0xdc07), to: &data) // ObjectFileName.
        PTPCodec.append(UInt16(0xffff), to: &data) // PTP string type.
        data.append(UInt8(name.utf16.count + 1))
        for unit in name.utf16 { PTPCodec.append(unit, to: &data) }
        PTPCodec.append(UInt16(0), to: &data)
        return data
    }

    /// Raw PTP transport preserves and validates transaction IDs.
    static func response(_ data: Data, transaction: UInt32, parameters expectedCount: Int) throws -> [UInt32] {
        guard data.count >= 12, data.count <= 32, data.count.isMultiple(of: 4), (0...5).contains(expectedCount) else {
            throw SphairaUploadError.invalidResponse
        }
        let bytes = Array(data)
        func number(_ start: Int, _ count: Int) -> UInt32 {
            (0..<count).reduce(0) { $0 | (UInt32(bytes[start + $1]) << ($1 * 8)) }
        }
        guard number(0, 4) == data.count, number(4, 2) == 3,
              number(8, 4) == transaction else { throw SphairaUploadError.invalidResponse }
        let code = UInt16(number(6, 2))
        guard code == 0x2001 else { throw SphairaUploadError.responseCode(code) }
        guard data.count == 12 + expectedCount * 4 else { throw SphairaUploadError.invalidResponse }
        return (0..<expectedCount).map { number(12 + $0 * 4, 4) }
    }

    private static func header(length: UInt32, type: UInt16, code: UInt16, transaction: UInt32) -> Data {
        var data = Data()
        PTPCodec.append(length, to: &data); PTPCodec.append(type, to: &data)
        PTPCodec.append(code, to: &data); PTPCodec.append(transaction, to: &data)
        return data
    }
}

enum SphairaUploadError: Error, Equatable {
    case invalidDataset, invalidResponse, responseCode(UInt16)
    case unsupportedSession, invalidSource, sourceChanged, shortRead
}
