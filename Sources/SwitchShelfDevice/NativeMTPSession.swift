import CDBIBridge
import Foundation

struct MTPStorage: Sendable, Equatable { let id: UInt32; let name: String }
struct MTPObject: Sendable, Equatable {
    let id: UInt32
    let parentID: UInt32
    let storageID: UInt32
    let name: String
    let isFolder: Bool
}
protocol InventoryTransport: Sendable {
    func storages() async throws -> [MTPStorage]
    func children(storage: UInt32, parent: UInt32) async throws -> [UInt32]
    func object(id: UInt32) async throws -> MTPObject
    func close() async throws
}

/// All native calls are actor-confined; the C gate additionally excludes other instances.
actor NativeMTPSession: InventoryTransport {
    private final class Handle: @unchecked Sendable {
        var pointer: OpaquePointer?
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        func close() { if let pointer { ss_mtp_close(pointer); self.pointer = nil } }
        deinit { close() }
    }
    private let handle: Handle
    init(runtimePath: String?) throws {
        var pointer: OpaquePointer?
        var error = ss_mtp_error()
        let result = runtimePath.map { path in
            path.withCString { ss_mtp_open($0, &pointer, &error) }
        } ?? ss_mtp_open(nil, &pointer, &error)
        try Self.check(result, error)
        guard let pointer else { throw DeviceServiceError(code: .transport, message: "MTP session missing after open.") }
        handle = Handle(pointer)
    }
    private var pointer: OpaquePointer {
        get throws {
            guard let value = handle.pointer else { throw DeviceServiceError(code: .transport, message: "MTP session closed.") }
            return value
        }
    }
    func close() { handle.close() }
    func storages() throws -> [MTPStorage] {
        var values: UnsafeMutablePointer<ss_mtp_storage>?
        var count = 0
        var error = ss_mtp_error()
        try Self.check(ss_mtp_get_storages(try pointer, &values, &count, &error), error)
        defer { ss_mtp_free_storages(values, count) }
        guard let values else { return [] }
        return try UnsafeBufferPointer(start: values, count: count).map { value in
            guard let name = value.name.flatMap({ String(validatingCString: $0) }) else {
                throw DeviceServiceError(code: .invalidMetadata, message: "MTP storage name is not valid UTF-8.")
            }
            return MTPStorage(id: value.id, name: name)
        }
    }
    func children(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        var values: UnsafeMutablePointer<UInt32>?
        var count = 0
        var error = ss_mtp_error()
        try Self.check(ss_mtp_get_children(try pointer, storage, parent, &values, &count, &error), error)
        defer { ss_mtp_free(values) }
        guard count <= 100_000 else { throw DeviceServiceError(code: .resourceLimit, message: "MTP folder exceeds the 100000-object safety limit.") }
        guard let values else { return [] }
        return Array(UnsafeBufferPointer(start: values, count: count))
    }
    func object(id: UInt32) throws -> MTPObject {
        var value = ss_mtp_object()
        var error = ss_mtp_error()
        try Self.check(ss_mtp_get_object(try pointer, id, &value, &error), error)
        defer { ss_mtp_clear_object(&value) }
        guard let name = value.name.flatMap({ String(validatingCString: $0) }) else {
            throw DeviceServiceError(code: .invalidMetadata, message: "MTP object name is not valid UTF-8.")
        }
        return MTPObject(id: value.id, parentID: value.parent_id, storageID: value.storage_id,
                         name: name, isFolder: value.is_folder != 0)
    }
    private static func check(_ status: Int32, _ error: ss_mtp_error) throws {
        guard status != 0 else { return }
        let code: DeviceServiceError.Code
        let message: String
        switch status {
        case 1:
            code = .runtimeMissing
            message = "未找到 libmtp ABI 9 运行库。发布版需在 Contents/Frameworks 内附带 libmtp.dylib 及 libusb 依赖；开发环境可提供 SWITCHSHELF_LIBMTP_PATH（绝对路径）。也可使用默认原生 ImageCaptureCore 通道。"
        case 2:
            code = .runtimeIncompatible; message = "libmtp/libusb 运行库缺少所需 ABI 符号；请使用经过审核的 ABI 9 动态库及依赖。"
        case 3:
            code = .busy; message = "只读 MTP 会话正在使用中；请等待当前操作完成。"
        case 4:
            code = .noDevice; message = "未发现 057e:201d MTP 候选设备；请连接数据线并进入 DBI → Run MTP responder。"
        case 5:
            code = .multipleDevices; message = "检测到多个 Switch MTP 候选设备；目前只支持一台活动设备，请由用户选择保留目标连接。"
        case 6:
            code = .accessDeniedOrBusy
            message = "libmtp 未能打开 MTP 会话：可能为访问权限、ptpcamerad/其他客户端占用、模式不符或断开，底层 API 未提供可区分的错误码。请优先使用原生 ImageCaptureCore 通道，关闭用户启动的其他 MTP 客户端，并停留在 DBI Run MTP responder；不要杀系统进程或修改全局相机设置。"
        case 8:
            code = .invalidMetadata; message = "MTP 返回无效或过长的对象/存储元数据；清单不能视为完整。"
        case 9:
            code = .resourceLimit; message = "MTP 元数据分配失败；清单不能视为完整。"
        default:
            code = .transport; message = "MTP 枚举失败或连接中断；请检查 DBI 模式、连接及其他客户端后手动重试，不能据此判断设备为空。"
        }
        throw DeviceServiceError(code: code, message: message, nativeCode: error.native_code == 0 ? nil : Int(error.native_code))
    }
}
