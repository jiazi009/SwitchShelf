#!/usr/bin/env python3
"""Smoke the actual compiled helper's entry guards; never authorize a USB operation."""
from pathlib import Path
import os, subprocess, tempfile, uuid
root = Path(__file__).resolve().parents[1]
helper = root / '.build/debug/switchshelf-probe'
assert helper.is_file(), 'Build switchshelf-probe first'
unauth = subprocess.run([str(helper), '--device-file-worker', str(uuid.uuid4()), '/nonexistent'],
                        capture_output=True, timeout=5)
assert unauth.returncode == 64, unauth.returncode
with tempfile.TemporaryDirectory(prefix='SwitchShelf-file-helper-smoke-') as temporary:
    directory = Path(temporary).resolve()
    directory.chmod(0o700)
    request = directory / 'request.json'
    request.write_text('{}')
    request.chmod(0o600)
    token = str(uuid.uuid4())
    environment = os.environ.copy()
    environment['SWITCHSHELF_DEVICE_FILE_TOKEN'] = token
    environment['SWITCHSHELF_DEVICE_FILE_PARENT_PID'] = str(os.getpid())
    rejected = subprocess.run([str(helper), '--device-file-worker', token, str(directory)],
                              env=environment, capture_output=True, timeout=5)
    assert rejected.returncode == 1, (rejected.returncode, rejected.stdout, rejected.stderr)
    assert not (directory / 'result.json').exists(), 'Malformed request reached a worker result'
    # Exercise the real client's private request directory and decoder as well.
    # The deliberately impossible registry ID must fail before any libusb open.
    source = directory / 'HelperClientSmoke.swift'
    source.write_text('''
import Foundation
import SwitchShelfDevice
@main struct HelperClientSmoke {
    static func main() async throws {
        let request = MTPFileRequest.storages()
        let client = BoundedDeviceFileClient(helperURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let value = try await client.execute(request,
            expectedDeviceSignature: "usb-registry-file-helper-intentionally-invalid", timeoutSeconds: 5)
        precondition(value.requestID == request.id && value.operation == .storages)
        precondition(value.outcome == .failed && value.releaseVerified)
        let fenced = await client.hasUnverifiedWorker
        precondition(!fenced)
        print("PASS: actual client/helper private envelope reaches pre-open device signature guard")
    }
}
''')
    binary = directory / 'HelperClientSmoke'
    modules = root / '.build/debug'
    modulemap = root / '.build/out/Intermediates.noindex/SwitchShelf.build/Debug/CDBIBridge-t.build/CDBIBridge.modulemap'
    subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-target', 'arm64-apple-macosx26.0',
                    '-module-cache-path', str(directory / 'modules'), '-I', str(modules),
                    '-Xcc', '-fmodule-map-file=' + str(modulemap), str(source), '-L', str(modules),
                    '-lSwitchShelfDevice', '-lSwitchShelfDomain', str(modules / 'CDBIBridge.o'),
                    '-framework', 'IOKit', '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(helper)], check=True, timeout=10)
print('PASS: actual helper rejects missing token and malformed private request before USB')
