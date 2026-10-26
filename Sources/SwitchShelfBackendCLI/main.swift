import Darwin
import Foundation
import SwitchShelfBackendInstall
import SwitchShelfDevice
import SwitchShelfDomain

private let usage = """
Usage: switchshelf-backend <command> [options]

Commands:
  discover [--wait seconds] [--json]
      Read-only IOKit enumeration. Reports whether a DBI Backend descriptor
      (057e:3000) is present. Never opens the device.

  install --file <absolute path> [options]
      One reviewed DBI Backend attempt for exactly one .nsp/.xci/.nsz/.xcz file.
      Waits for 057e:3000, then opens the device, serves only the offered file,
      journals conservative progress and reports host-side transfer evidence.
      It never selects SD/NAND on the device and cannot confirm installation.

Options:
  --file <path>       Absolute source package path (required for install).
  --wait <seconds>    Wait time for the Backend device to appear (default 300).
  --timeout <seconds> Session budget in seconds, 30...7200 (default 1800).
  --journal <path>    Journal path (default ~/Library/Application Support/SwitchShelf/backend/journal.json).
  --chunk <bytes>     Host data chunk size, 1...1048576 (default 1048576).
  --target <sd|nand>  Local intent only; the device selects the destination.
  --no-wait           Do not wait for the device to appear.
  --json              Accepted for symmetry; JSON is always emitted.

Exit codes: 0 host transfer complete (device asked EXIT; installation unconfirmed),
1 failed, 2 incomplete transfer, 3 device unavailable, 4 device busy,
5 journal unavailable, 64 usage, 124 hard deadline, 130 cancelled.
"""

private struct BasicReport: Codable {
    let outcome: String
    let message: String
    let exitCode: Int32
}

private struct DeviceSummary: Codable {
    let name: String
    let vendorID: UInt16
    let productID: UInt16
}

private struct DiscoverReport: Codable {
    let found: Bool
    let state: String
    let message: String
    let devices: [DeviceSummary]
    let waitedSeconds: Int
}

private func stderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}

/// Deliberately non-generic apart from the encoder call, and only writes stdout.
/// Keeping this minimal avoids the release-optimizer hang observed with a
/// generic `-> Never` emitter that also did the encoding in its body.
private func finish(_ data: Data, exitCode: Int32) -> Never {
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(exitCode)
}

private func jsonData(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(value)) ?? Data()
}

private func usageError(_ message: String) -> Never {
    stderr("switchshelf-backend: \(message)\n\n\(usage)\n")
    exit(64)
}

private func isBackendDescriptor(_ device: DeviceDescriptor) -> Bool {
    device.vendorID == 0x057e && device.productID == 0x3000
}

private func waitForBackendDevice(seconds: Int) async -> DeviceDiscovery {
    let service = DeviceService()
    var last = await service.discover()
    guard seconds > 0 else { return last }
    let deadline = Date().addingTimeInterval(Double(seconds))
    var lastNotice = Date.distantPast
    while true {
        if last.devices.contains(where: isBackendDescriptor) { return last }
        if Date() >= deadline { break }
        if Date().timeIntervalSince(lastNotice) >= 5 {
            stderr("等待 DBI Backend 设备 (057e:3000)… 当前：\(last.message)\n")
            lastNotice = Date()
        }
        try? await Task.sleep(for: .seconds(1))
        last = await service.discover()
    }
    return last
}

private func runDiscover(_ arguments: [String]) async -> Never {
    var waitSeconds = 0
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--wait":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), (0...3_600).contains(value) else {
                usageError("--wait 需要 0...3600 的整数")
            }
            waitSeconds = value
            index += 2
        case "--json":
            index += 1
        default:
            usageError("未知参数 \(arguments[index])")
        }
    }
    let discovery = await waitForBackendDevice(seconds: waitSeconds)
    let backendDevices = discovery.devices.filter(isBackendDescriptor)
    let report = DiscoverReport(found: !backendDevices.isEmpty,
                                state: discovery.state.rawValue,
                                message: discovery.message,
                                devices: backendDevices.map {
                                    DeviceSummary(name: $0.name, vendorID: $0.vendorID, productID: $0.productID)
                                },
                                waitedSeconds: waitSeconds)
    if backendDevices.isEmpty {
        stderr("未发现 057e:3000；请在 Switch 的 DBI 主菜单选择 “Install title from DBIbackend”。\n")
    } else {
        stderr("已发现 DBI Backend 描述符 057e:3000（尚未打开）。\n")
    }
    finish(jsonData(report), exitCode: backendDevices.isEmpty ? 3 : 0)
}

private final class ProgressPrinter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercent = -1
    private var finished = false

    func update(sent: UInt64, total: UInt64) {
        guard total > 0 else { return }
        let percent = Int((Double(sent) / Double(total)) * 100)
        lock.lock()
        defer { lock.unlock() }
        guard percent != lastPercent else { return }
        lastPercent = percent
        stderr("\r主机侧进度 \(percent)%  \(sent)/\(total) 字节")
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        stderr("\n")
    }
}

private func runInstall(_ arguments: [String]) async -> Never {
    var filePath: String?
    var waitSeconds = 300
    var timeoutSeconds = 1_800
    var journalPath: String?
    var chunkSize = 1_048_576
    var target = "sd"
    var index = 0
    while index < arguments.count {
        switch arguments[index] {
        case "--file":
            guard index + 1 < arguments.count else { usageError("--file 需要参数") }
            filePath = arguments[index + 1]
            index += 2
        case "--wait":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), (0...3_600).contains(value) else {
                usageError("--wait 需要 0...3600 的整数")
            }
            waitSeconds = value
            index += 2
        case "--timeout":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), (30...7_200).contains(value) else {
                usageError("--timeout 需要 30...7200 的整数")
            }
            timeoutSeconds = value
            index += 2
        case "--journal":
            guard index + 1 < arguments.count else { usageError("--journal 需要参数") }
            journalPath = arguments[index + 1]
            index += 2
        case "--chunk":
            guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), (1...1_048_576).contains(value) else {
                usageError("--chunk 需要 1...1048576 的整数")
            }
            chunkSize = value
            index += 2
        case "--target":
            guard index + 1 < arguments.count else { usageError("--target 需要参数") }
            let value = arguments[index + 1]
            guard ["sd", "nand"].contains(value) else { usageError("--target 只接受 sd 或 nand") }
            target = value
            index += 2
        case "--json":
            index += 1
        case "--no-wait":
            waitSeconds = 0
            index += 1
        default:
            usageError("未知参数 \(arguments[index])")
        }
    }

    guard let filePath else { usageError("install 需要 --file") }
    let expanded = (filePath as NSString).expandingTildeInPath
    let fileURL = URL(fileURLWithPath: expanded).standardizedFileURL
    guard fileURL.path.hasPrefix("/") else { usageError("--file 必须是绝对路径") }
    let journalURL = journalPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        ?? BackendInstallLocation.defaultJournalURL

    stderr("目标文件：\(fileURL.path)\n")
    stderr("传输记录：\(journalURL.path)\n")
    stderr("等待 DBI Backend 设备（057e:3000），最长 \(waitSeconds) 秒…\n")
    let discovery = await waitForBackendDevice(seconds: waitSeconds)
    guard discovery.devices.contains(where: isBackendDescriptor) else {
        let report = BasicReport(outcome: BackendInstallOutcome.deviceUnavailable.rawValue,
                                 message: "未发现 DBI Backend 描述符 057e:3000。请在 Switch 上打开 DBI 主菜单并按 Y 选择 “Install title from DBIbackend”，然后重试。未访问设备。",
                                 exitCode: BackendInstallOutcome.deviceUnavailable.exitCode)
        finish(jsonData(report), exitCode: report.exitCode)
    }
    stderr("已发现 057e:3000。开始只读预检与显式打开。\n")

    let hardSeconds = timeoutSeconds + 120
    Task.detached {
        try? await Task.sleep(for: .seconds(hardSeconds))
        stderr("\nswitchshelf-backend: 硬超时，设备状态未确认。\n")
        exit(124)
    }

    let printer = ProgressPrinter()
    let request = BackendInstallRequest(fileURL: fileURL,
                                        journalURL: journalURL,
                                        sessionTimeoutSeconds: timeoutSeconds,
                                        maximumChunkSize: chunkSize,
                                        intendedTarget: target,
                                        progress: { sent, total in
                                            printer.update(sent: sent, total: total)
                                        })
    let report = await BackendInstallRunner.run(request, provider: USBBackendTransportProvider())
    printer.finish()
    finish(jsonData(report), exitCode: report.exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    stderr(usage)
    exit(64)
}
switch command {
case "install":
    await runInstall(Array(arguments.dropFirst()))
case "discover":
    await runDiscover(Array(arguments.dropFirst()))
case "--help", "-h", "help":
    stderr(usage)
    exit(0)
default:
    usageError("未知命令 \(command)")
}
