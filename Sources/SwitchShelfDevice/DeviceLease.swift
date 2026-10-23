import Darwin
import Foundation

/// One machine-wide advisory lock for every process that can open a Switch USB
/// session (the MTP probe today, Backend/SMB helpers later). It is a plain
/// `flock` on an owner-only file: acquisition is non-blocking, and the kernel
/// drops the lock when the holding process exits or is killed, so a crashed
/// helper cannot leave a stale lease. In-process callers must still serialize
/// through their own actor; this only fences other processes.
public enum DeviceLeaseError: Error, LocalizedError, Sendable, Equatable {
    case busy
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .busy: "另一个进程正在使用 Switch USB 会话；请等待该操作结束。"
        case .unavailable: "无法创建或打开设备租约文件；未访问设备。"
        }
    }
}

public final class DeviceLease: @unchecked Sendable {
    /// Override for tests or isolated tooling; production processes must all use
    /// the default so the lock actually overlaps.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["SWITCHSHELF_DEVICE_LEASE_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SwitchShelf", isDirectory: true)
            .appendingPathComponent("device-lease.lock")
    }

    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Non-blocking. Returns `.busy` when any process (including this one via a
    /// second handle) already holds the lease.
    public static func acquire(at url: URL = defaultURL) throws -> DeviceLease {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw DeviceLeaseError.unavailable }
        // O_CLOEXEC keeps the lock out of child processes; otherwise a spawned
        // helper would inherit the descriptor and outlive its owner.
        let fd = url.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC, 0o600) }
        guard fd >= 0 else { throw DeviceLeaseError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? DeviceLeaseError.busy : DeviceLeaseError.unavailable
        }
        return DeviceLease(descriptor: fd)
    }

    public var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return descriptor >= 0
    }

    /// Idempotent. Closing the descriptor alone also releases the lock; the
    /// explicit `LOCK_UN` makes the intent obvious.
    public func release() {
        lock.lock()
        let fd = descriptor
        descriptor = -1
        lock.unlock()
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        _ = close(fd)
    }

    deinit { release() }
}
