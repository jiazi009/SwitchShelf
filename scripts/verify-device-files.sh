#!/bin/zsh
# Focused native file-manager regressions. All helper processes are synthetic;
# bootstrap is never called and all app data/defaults live in private fixtures.
set -euo pipefail
cd "${0:A:h:h}"
task_root="$PWD"
task_temporary="$(mktemp -d /private/tmp/switchshelf-device-files.XXXXXX)"
trap 'rm -rf "$task_temporary"' EXIT
mkdir -p "$task_root/.build/ui-module-cache" "$task_root/output/ui-review/device-files"
python3 - "$task_root" "$task_temporary" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:3])
for source in (root / 'Sources/SwitchShelfApp').glob('*.swift'):
    if source.name == 'SwitchShelfApp.swift':
        continue
    text = source.read_text().replace('UserDefaults.standard', 'UserDefaults(suiteName: "local.switchshelf.device-files.fixture")!')
    if source.name == 'AppModel.swift':
        text = text.replace('NSWorkspace.shared.runningApplications', '[NSRunningApplication]()')
        text += '''
extension AppModel {
    func seedDeviceFileIntegration(_ root: URL) throws {
        let url = root.appendingPathComponent("fixture-base.nsp")
        try Data(repeating: 0x41, count: 64).write(to: url)
        let content = LocalContent(id: url.path, titleID: "0100AAAA00000000", kind: .base, rawVersion: 0,
                                   fileURL: url, byteCount: 64, format: .nsp)
        let game = Game(id: "file-fixture", title: "Synthetic game only", contents: [content], identification: .matched)
        snapshot = LibrarySnapshot(sources: [LibrarySource(url: root, name: "Synthetic source", availability: .online)], games: [game])
        plan = [PlanItem(game: game)]
        deviceDiscovery = DeviceDiscovery(state: .waitingForMTP, devices: [DeviceDescriptor(
            id: "usb-registry-fixture-A", name: "Synthetic Switch", vendorID: 0x057e, productID: 0x201d)], message: "Synthetic descriptors only")
        isBootstrapped = true
        selection = .files
    }
}
'''
    if source.name == 'DeviceFileManagerModel.swift':
        text += '''
extension DeviceFileManagerModel {
    func waitForDeviceFileFixture() async { await operationTask?.value }
    func seedDeviceFileProgressFixture() {
        isBusy = true
        operationTitle = "上传 readme.txt"
        progress = MTPFileProgress(requestID: UUID().uuidString, phase: "正在发送文件", bytesTransferred: 524288, totalBytes: 1048576)
    }
    func clearDeviceFileProgressFixture() { isBusy = false; progress = nil }
    func replaceDeviceFileEntriesFixture(_ entries: [MTPFileEntry]) { listing?.entries = entries; selectedEntryID = nil }
}
'''
    (temporary / source.name).write_text(text)
(temporary / 'DeviceFilesRegression.swift').write_text((root / 'scripts/verify-device-files.swift').read_text())
PY

task_modules="$task_root/.build/debug"
task_intermediates="$task_root/.build/out/Intermediates.noindex/SwitchShelf.build/Debug"
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
  -module-cache-path "$task_root/.build/ui-module-cache" \
  -I "$task_modules" -I Sources/CSQLite \
  -Xcc "-fmodule-map-file=$task_intermediates/CDBIBridge-t.build/CDBIBridge.modulemap" \
  -Xcc "-fmodule-map-file=$task_intermediates/CDBIBackendUSB-t.build/CDBIBackendUSB.modulemap" \
  "$task_temporary"/*.swift \
  -L "$task_modules" -lSwitchShelfDomain -lSwitchShelfLibrary -lSwitchShelfDevice -lSwitchShelfBackend \
  "$task_modules/CDBIBridge.o" "$task_modules/CDBIBackendUSB.o" \
  -framework AppKit -framework SwiftUI -framework IOKit -lsqlite3 \
  -o "$task_temporary/DeviceFilesRegression"
"$task_temporary/DeviceFilesRegression" "$task_temporary" "$task_root/output/ui-review/device-files"
python3 - "$task_root" <<'PY'
from pathlib import Path
import hashlib,json,sys
root=Path(sys.argv[1]); directory=root/'output/ui-review/device-files'
manifest=json.loads((directory/'manifest.json').read_text())
manifest['productionSourceSHA256']={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
 for p in sorted((root/'Sources/SwitchShelfApp').glob('*.swift'))}
for item in manifest['captures']:
 item['imageSHA256']=hashlib.sha256((directory/item['file']).read_bytes()).hexdigest()
(directory/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print('PASS: current source/image hashes recorded for focused device-file evidence')
PY
