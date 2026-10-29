import Darwin
import Foundation
import SwitchShelfDevice
import SwitchShelfDomain

struct ProbeFailure: Codable {
    var code: String
    var message: String
    var nativeCode: Int?
}
struct ProbeResult: Codable {
    var schemaVersion = 1
    var mode: String
    var status: String
    var transport: String?
    var discovery: DeviceDiscovery?
    var inventory: InstalledInventory?
    var error: ProbeFailure?
}
let usage = """
Usage: switchshelf-probe [discover|inventory|storages] [--timeout 1...120] [--transport libusb] [--json]

Default: discover (IOKit only; never opens MTP). JSON is always emitted.
inventory is explicitly opt-in, metadata-only, and must not overlap another device client.
Supported inventory storages: sphaira Games and DBI Installed games. Other storages are never traversed.
storages is explicitly opt-in and lists storage descriptions only; it never lists content objects.
Inventory transport: libusb only, shared with installation. No alternate transport or automatic fallback.
Installation is not a public probe mode; the app uses a separate token-gated, explicitly confirmed direct worker.
Exit: 0 successful, 2 incomplete inventory (also successful storage-only diagnostics), 1 error, 64 usage, 124 deadline exceeded.
Inventory identities are session-scoped; runtime environment remains unknown.
"""
func encoded(_ result: ProbeResult) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return (try? encoder.encode(result)) ?? Data("{\"status\":\"error\",\"error\":{\"code\":\"encoding\",\"message\":\"JSON encoding failed\"}}".utf8)
}
func emit(_ result: ProbeResult, exitCode: Int32) -> Never {
    FileHandle.standardOutput.write(encoded(result))
    FileHandle.standardOutput.write(Data([10]))
    Darwin.exit(exitCode)
}
func failure(mode: String, code: String, message: String, transport: String? = nil) -> ProbeResult {
    ProbeResult(mode: mode, status: "error", transport: transport,
                error: ProbeFailure(code: code, message: message))
}

// Worker output is an owner-only temporary JSON file. Native stdout/stderr are discarded
// by the parent: no serials or unrelated libusb diagnostics can contaminate JSON/logs.
let arguments = Array(CommandLine.arguments.dropFirst())
let invocationParentPID = getppid()
// Device file operations use one direct, parent-authenticated child. Normal probe
// modes can never reach upload/download code, and the child cannot spawn a USB grandchild.
if arguments.first == "--device-file-worker" {
    guard arguments.count == 3,
          ProcessInfo.processInfo.environment["SWITCHSHELF_DEVICE_FILE_TOKEN"] == arguments[1],
          UUID(uuidString: arguments[1]) != nil,
          getppid() > 1,
          ProcessInfo.processInfo.environment["SWITCHSHELF_DEVICE_FILE_PARENT_PID"] == String(getppid()),
          let fileTimeout = UInt32(ProcessInfo.processInfo.environment["SWITCHSHELF_DEVICE_FILE_TIMEOUT"] ?? "123"),
          (1...14_403).contains(fileTimeout) else {
        emit(failure(mode: "files", code: "unconfirmed", message: "Device file operations require the reviewed app flow."), exitCode: 64)
    }
    // Independent fallback if the parent supervisor itself cannot make progress.
    // This direct process owns the USB handle; process exit releases that ownership.
    signal(SIGALRM) { _ in Darwin._exit(124) }
    alarm(fileTimeout)
    let parentPID = getppid()
    Task.detached {
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            if getppid() != parentPID { Darwin._exit(1) }
        }
    }
    Task {
        let code = await DeviceFileProcessWorker.run(directory: URL(fileURLWithPath: arguments[2]))
        Darwin.exit(code)
    }
    RunLoop.main.run()
    Darwin.exit(1)
}
// Separate explicit installation entry point. Never reached by discover/inventory/storages.
// A direct parent process passes one reviewed, confirmed request in a private directory.
if arguments.first == "--sphaira-install-worker" {
    guard arguments.count == 3,
          ProcessInfo.processInfo.environment["SWITCHSHELF_INSTALL_TOKEN"] == arguments[1],
          UUID(uuidString: arguments[1]) != nil,
          getppid() > 1,
          ProcessInfo.processInfo.environment["SWITCHSHELF_INSTALL_PARENT_PID"] == String(getppid()) else {
        emit(failure(mode: "install", code: "unconfirmed", message: "Installation requires the app confirmation flow."), exitCode: 64)
    }
    let parentPID = getppid()
    // If the app quits/crashes, do not leave an orphan USB sender running.
    Task.detached {
        while true {
            try? await Task.sleep(for: .milliseconds(200))
            if getppid() != parentPID { Darwin._exit(1) }
        }
    }
    Task {
        let result = await SphairaInstallWorker.run(directory: URL(fileURLWithPath: arguments[2]))
        Darwin.exit(result.transfer.outcome == .transferredAwaitingConfirmation && result.transfer.releaseVerified ? 0 : 1)
    }
    RunLoop.main.run()
    Darwin.exit(1)
}
if arguments.first == "--internal-worker", arguments.count == 4,
   ProcessInfo.processInfo.environment["SWITCHSHELF_PROBE_WORKER_TOKEN"] == arguments[1],
   UUID(uuidString: arguments[1]) != nil,
   ["discover", "inventory", "storages"].contains(arguments[2]),
   invocationParentPID > 1,
   ProcessInfo.processInfo.environment["SWITCHSHELF_PROBE_PARENT_PID"] == String(invocationParentPID) {
    let mode = arguments[2]
    let output = URL(fileURLWithPath: arguments[3])
    let transport = "libusb"
    // A supervisor killed by its caller cannot leave a native worker orphaned.
    // A Dispatch timer remains independent of blocked Swift actor/native calls.
    let parentWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    parentWatch.schedule(deadline: .now(), repeating: .milliseconds(200))
    let expectedParentPID = invocationParentPID
    parentWatch.setEventHandler { @Sendable [expectedParentPID] in
        if getppid() != expectedParentPID { Darwin._exit(1) }
    }
    parentWatch.resume()
    Task { @MainActor in
        let result: ProbeResult
        var code: Int32 = 0
        do {
            let service = DeviceService()
            if mode == "discover" {
                let discovery = await service.discover()
                code = discovery.state == .error ? 1 : 0
                result = ProbeResult(mode: mode, status: code == 0 ? "ok" : "error", discovery: discovery)
            } else {
                // One machine-wide lease covers MTP and any future Backend helper.
                // `discover` only enumerates IOKit descriptors and needs no lease.
                let lease = try DeviceLease.acquire()
                defer { lease.release() }
                let inventory: InstalledInventory
                if mode == "storages" {
                    inventory = try await service.readStorageDiagnostics()
                } else {
                    inventory = try await service.readInventory()
                }
                code = inventory.isComplete ? 0 : 2
                result = ProbeResult(mode: mode, status: inventory.isComplete ? "ok" : "partial",
                                     transport: transport, inventory: inventory)
            }
        } catch let error as DeviceLeaseError {
            code = 1
            result = ProbeResult(mode: mode, status: "error", transport: transport,
                error: ProbeFailure(code: error == .busy ? "busy" : "leaseUnavailable",
                                    message: error.errorDescription ?? "Device lease unavailable."))
        } catch let error as DeviceServiceError {
            code = 1
            result = ProbeResult(mode: mode, status: "error", transport: transport,
                error: ProbeFailure(code: error.code.rawValue, message: error.message, nativeCode: error.nativeCode))
        } catch {
            code = 1
            result = failure(mode: mode, code: "operationFailed",
                             message: "Read-only probe failed or was cancelled; no complete inventory is available.", transport: transport)
        }
        do { try encoded(result).write(to: output, options: .atomic) }
        catch { Darwin.exit(1) }
        Darwin.exit(code)
    }
    withExtendedLifetime(parentWatch) { RunLoop.main.run() }
    Darwin.exit(1)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage); Darwin.exit(0)
}
var mode = "discover"
var transport = "libusb"
var timeout: Int?
var index = 0
if let first = arguments.first, ["discover", "inventory", "storages"].contains(first) { mode = first; index = 1 }
while index < arguments.count {
    let option = arguments[index]
    if option == "--json" { index += 1; continue }
    guard index + 1 < arguments.count else {
        emit(failure(mode: mode, code: "usage", message: usage), exitCode: 64)
    }
    let value = arguments[index + 1]
    if option == "--timeout", let seconds = Int(value), (1...120).contains(seconds) { timeout = seconds }
    else if option == "--transport", value == "libusb" { transport = value }
    else { emit(failure(mode: mode, code: "usage", message: usage), exitCode: 64) }
    index += 2
}
let seconds = timeout ?? (mode == "inventory" ? 60 : 10)
let manager = FileManager.default
let directory = manager.temporaryDirectory.appendingPathComponent("SwitchShelf-probe-\(UUID().uuidString)", isDirectory: true)
do {
    try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
} catch {
    emit(failure(mode: mode, code: "temporaryOutput", message: "Cannot create private probe output directory."), exitCode: 1)
}
let output = directory.appendingPathComponent("result.json")
let process = Process()
process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let token = UUID().uuidString
process.arguments = ["--internal-worker", token, mode, output.path]
var environment = ProcessInfo.processInfo.environment
environment["SWITCHSHELF_PROBE_WORKER_TOKEN"] = token
environment["SWITCHSHELF_PROBE_PARENT_PID"] = String(getpid())
environment.removeValue(forKey: "SWITCHSHELF_MTP_TRANSPORT")
process.environment = environment
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
process.standardInput = FileHandle.nullDevice
let finished = DispatchSemaphore(value: 0)
let cancelPath = ProcessInfo.processInfo.environment["SWITCHSHELF_PROBE_CANCEL_PATH"]
func cancellationRequested() -> Bool {
    getppid() != invocationParentPID || cancelPath.map { FileManager.default.fileExists(atPath: $0) } == true
}
if cancellationRequested() {
    try? manager.removeItem(at: directory)
    emit(failure(mode: mode, code: "cancelled", message: "Read-only probe cancelled before worker launch.",
        transport: mode == "discover" ? nil : transport), exitCode: 1)
}
process.terminationHandler = { _ in finished.signal() }
do { try process.run() }
catch {
    try? manager.removeItem(at: directory)
    emit(failure(mode: mode, code: "launchFailed", message: "Cannot launch isolated read-only probe worker."), exitCode: 1)
}
let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
while finished.wait(timeout: .now() + .milliseconds(50)) == .timedOut {
    let cancelled = cancellationRequested()
    guard cancelled || ContinuousClock.now >= deadline else { continue }
    process.terminate()
    if finished.wait(timeout: .now() + .milliseconds(300)) == .timedOut {
        Darwin.kill(process.processIdentifier, SIGKILL)
        if finished.wait(timeout: .now() + .milliseconds(700)) == .timedOut {
            // No new USB operation is safe without positive direct-worker exit.
            emit(failure(mode: mode, code: "workerExitUnverified", message: "Cannot verify the read-only worker exited; do not retry while it may still own the USB session.", transport: mode == "discover" ? nil : transport), exitCode: 1)
        }
    }
    try? manager.removeItem(at: directory)
    if cancelled {
        emit(failure(mode: mode, code: "cancelled", message: "Read-only probe cancelled; direct USB worker exit verified, inventory coverage unknown.", transport: mode == "discover" ? nil : transport), exitCode: 1)
    }
    emit(failure(mode: mode, code: "timeout", message: "Read-only probe exceeded \(seconds)s; worker stopped, coverage unknown. Keep sphaira/DBI in MTP mode and check permissions/other clients before a manual retry.", transport: mode == "discover" ? nil : transport), exitCode: 124)
}
let result: ProbeResult
do {
    let attributes = try manager.attributesOfItem(atPath: output.path)
    guard let size = attributes[.size] as? NSNumber, size.int64Value <= 32 * 1024 * 1024 else {
        throw CocoaError(.fileReadTooLarge)
    }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    result = try decoder.decode(ProbeResult.self, from: Data(contentsOf: output))
} catch {
    try? manager.removeItem(at: directory)
    emit(failure(mode: mode, code: "workerFailed", message: "Probe worker returned no valid bounded JSON result; inventory coverage is unknown.", transport: mode == "discover" ? nil : transport), exitCode: 1)
}
try? manager.removeItem(at: directory)
emit(result, exitCode: process.terminationStatus)
