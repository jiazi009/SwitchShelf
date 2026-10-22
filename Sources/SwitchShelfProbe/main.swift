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
Usage: switchshelf-probe [discover|inventory] [--timeout 1...120] [--transport native|libmtp] [--json]

Default: discover (IOKit only; never opens MTP). JSON is always emitted.
inventory is explicitly opt-in, metadata-only, and must not overlap another device client.
Default transport: native (system ImageCaptureCore broker); libmtp is an explicit fallback.
Exit: 0 successful, 2 incomplete inventory, 1 error, 64 usage, 124 deadline exceeded.
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
if arguments.first == "--internal-worker", arguments.count == 4,
   ProcessInfo.processInfo.environment["SWITCHSHELF_PROBE_WORKER_TOKEN"] == arguments[1] {
    let mode = arguments[2]
    let output = URL(fileURLWithPath: arguments[3])
    let transport = ProcessInfo.processInfo.environment["SWITCHSHELF_MTP_TRANSPORT"] ?? "native"
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
                let inventory = try await service.readInventory()
                code = inventory.isComplete ? 0 : 2
                result = ProbeResult(mode: mode, status: inventory.isComplete ? "ok" : "partial",
                                     transport: transport, inventory: inventory)
            }
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
    RunLoop.main.run()
    Darwin.exit(1)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage); Darwin.exit(0)
}
var mode = "discover"
var transport = "native"
var timeout: Int?
var index = 0
if arguments.first == "discover" || arguments.first == "inventory" { mode = arguments[0]; index = 1 }
while index < arguments.count {
    let option = arguments[index]
    if option == "--json" { index += 1; continue }
    guard index + 1 < arguments.count else {
        emit(failure(mode: mode, code: "usage", message: usage), exitCode: 64)
    }
    let value = arguments[index + 1]
    if option == "--timeout", let seconds = Int(value), (1...120).contains(seconds) { timeout = seconds }
    else if option == "--transport", ["native", "libmtp"].contains(value) { transport = value }
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
environment["SWITCHSHELF_MTP_TRANSPORT"] = transport
process.environment = environment
process.standardOutput = FileHandle.nullDevice
process.standardError = FileHandle.nullDevice
process.standardInput = FileHandle.nullDevice
let finished = DispatchSemaphore(value: 0)
process.terminationHandler = { _ in finished.signal() }
do { try process.run() }
catch {
    try? manager.removeItem(at: directory)
    emit(failure(mode: mode, code: "launchFailed", message: "Cannot launch isolated read-only probe worker."), exitCode: 1)
}
if finished.wait(timeout: .now() + .seconds(seconds)) == .timedOut {
    process.terminate()
    if finished.wait(timeout: .now() + .milliseconds(300)) == .timedOut {
        Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + .milliseconds(300))
    }
    try? manager.removeItem(at: directory)
    emit(failure(mode: mode, code: "timeout", message: "Read-only probe exceeded \(seconds)s; worker stopped, coverage unknown. Keep DBI in Run MTP responder and check permissions/other clients before a manual retry.", transport: mode == "inventory" ? transport : nil), exitCode: 124)
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
    emit(failure(mode: mode, code: "workerFailed", message: "Probe worker returned no valid bounded JSON result; inventory coverage is unknown.", transport: mode == "inventory" ? transport : nil), exitCode: 1)
}
try? manager.removeItem(at: directory)
emit(result, exitCode: process.terminationStatus)
