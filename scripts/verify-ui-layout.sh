#!/bin/zsh
# Render current SwiftUI sources with isolated, explicitly synthetic fixtures.
# Requires a prior `swift build`. Add --live-dark for a native fixture-only window.
set -euo pipefail
cd "${0:A:h:h}"
task_root="$PWD"
task_temporary="$(mktemp -d /tmp/switchshelf-ui-layout.XXXXXX)"
trap 'rm -rf "$task_temporary"' EXIT
mkdir -p "$task_root/.build/ui-module-cache" "$task_root/output/ui-review/layout"

python3 - "$task_root" "$task_temporary" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:])
for source in (root / 'Sources/SwitchShelfApp').glob('*.swift'):
    if source.name not in ('SwitchShelfApp.swift', 'AppModel.swift', 'GameViews.swift'):
        (temporary / source.name).write_text(source.read_text())
model = (root / 'Sources/SwitchShelfApp/AppModel.swift').read_text()
model = model.replace('UserDefaults.standard', 'UserDefaults(suiteName: "local.switchshelf.ui-review.fixture")!')
model = model.replace('let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first\n'
    '            ?? FileManager.default.temporaryDirectory\n'
    '        return base.appendingPathComponent("SwitchShelf", isDirectory: true)',
    'return URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!, isDirectory: true)')
model += '''
extension AppModel {
    func seedUIReview(_ snapshot: LibrarySnapshot, plan: [PlanItem], page: SidebarItem, layout: LibraryLayout, inspector: Bool) {
        self.snapshot = snapshot
        self.plan = plan
        firstSeen = Dictionary(uniqueKeysWithValues: snapshot.games.map { ($0.id, Date()) })
        selection = page
        self.layout = layout
        coverSize = 172
        sortOrder = .title
        inspectorPresented = inspector
        cacheLoaded = true
        isBootstrapped = true
        deviceDiscovery = DeviceDiscovery(state: .disconnected, message: "UI fixture：未连接任何真实设备；不会执行 USB 枚举。")
        if inspector, let game = snapshot.games.first {
            selectedGameIDs = [game.id]
            activeGameID = game.id
        }
    }
}
'''
(temporary / 'AppModel.swift').write_text(model)
game = (root / 'Sources/SwitchShelfApp/GameViews.swift').read_text()
game = game.replace(
    'directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first\n'
    '            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))\n'
    '            .appendingPathComponent("SwitchShelf/CoverThumbnails", isDirectory: true)',
    'directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!, isDirectory: true)'
    '.appendingPathComponent("CoverThumbnails", isDirectory: true)')
(temporary / 'GameViews.swift').write_text(game)
PY

task_sources=("$task_temporary"/*.swift)
task_modules="$task_root/.build/debug"
task_intermediates="$task_root/.build/out/Intermediates.noindex/SwitchShelf.build/Debug"

swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
  -module-cache-path "$task_root/.build/ui-module-cache" \
  -I "$task_modules" -I Sources/CSQLite \
  -Xcc "-fmodule-map-file=$task_intermediates/CDBIBridge-t.build/CDBIBridge.modulemap" \
  -Xcc "-fmodule-map-file=$task_intermediates/CDBIBackendUSB-t.build/CDBIBackendUSB.modulemap" \
  "${task_sources[@]}" \
  scripts/verify-ui-layout.swift \
  -L "$task_modules" -lSwitchShelfDomain -lSwitchShelfLibrary -lSwitchShelfDevice -lSwitchShelfBackend \
  "$task_modules/CDBIBridge.o" "$task_modules/CDBIBackendUSB.o" \
  -framework AppKit -framework SwiftUI -framework IOKit -framework ImageCaptureCore -lsqlite3 \
  -o "$task_temporary/SwitchShelfUIReview"

SWITCHSHELF_UI_REVIEW_STATE="$task_temporary/state" \
  "$task_temporary/SwitchShelfUIReview" "$task_root/output/ui-review/layout" "$task_temporary" "$@"
