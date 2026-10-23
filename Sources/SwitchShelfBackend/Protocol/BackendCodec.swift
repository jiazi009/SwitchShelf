import Foundation

/// Independently implemented from the pinned official dbibackend host script.
/// See Docs/Reports/backend-protocol.md for the source and evidence limits.
enum BackendCodec {
    static let headerSize = 16
    static let rangePrefixSize = 16

    enum MessageType: UInt32, Sendable {
        case request = 0
        case response = 1
        case acknowledgement = 2
    }

    enum Command: UInt32, Sendable {
        case exit = 0
        case fileRange = 2
        case list = 3
    }

    struct Header: Equatable, Sendable {
        let type: MessageType
        let command: Command
        let payloadSize: UInt32

        func encoded() -> Data {
            var bytes = Data([0x44, 0x42, 0x49, 0x30])
            BackendCodec.append(type.rawValue, to: &bytes)
            BackendCodec.append(command.rawValue, to: &bytes)
            BackendCodec.append(payloadSize, to: &bytes)
            return bytes
        }
    }

    struct FileRange: Sendable {
        let size: UInt32
        let offset: UInt64
        let nameBytes: Data
    }

    static func decodeHeader(_ data: Data) throws -> Header {
        guard data.count == headerSize else { throw BackendError.protocolViolation }
        let bytes = Array(data)
        guard bytes[0..<4].elementsEqual([0x44, 0x42, 0x49, 0x30]),
              let type = MessageType(rawValue: uint32(bytes, at: 4)) else {
            throw BackendError.protocolViolation
        }
        guard let command = Command(rawValue: uint32(bytes, at: 8)) else {
            // The script declares legacy LIST=1 but never handles it.
            throw BackendError.unsupportedCommand
        }
        return Header(type: type, command: command, payloadSize: uint32(bytes, at: 12))
    }

    static func decodeRange(_ data: Data) throws -> FileRange {
        guard data.count > rangePrefixSize else { throw BackendError.protocolViolation }
        let prefix = Array(data.prefix(rangePrefixSize))
        let nameSize = uint32(prefix, at: 12)
        guard UInt64(nameSize) == UInt64(data.count - rangePrefixSize) else {
            throw BackendError.protocolViolation
        }
        let name = Data(data.dropFirst(rangePrefixSize))
        guard let text = String(data: name, encoding: .utf8), validName(text) else {
            throw BackendError.protocolViolation
        }
        return FileRange(size: uint32(prefix, at: 0), offset: uint64(prefix, at: 4), nameBytes: name)
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
            }
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[index + $1]) << ($1 * 8) }
    }

    private static func uint64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[index + $1]) << ($1 * 8) }
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
