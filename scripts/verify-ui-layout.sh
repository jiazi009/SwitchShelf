#!/bin/zsh
# Render current SwiftUI sources with isolated, explicitly synthetic fixtures.
# Requires a prior `swift build`. Add --live-dark for a native fixture-only window.
# --empty-library-window [--dark] exercises the real production WindowGroup with
# isolated empty/source-removal fixtures and a bounded process lifetime.
set -euo pipefail
cd "${0:A:h:h}"
task_root="$PWD"
task_temporary="$(mktemp -d /tmp/switchshelf-ui-layout.XXXXXX)"
trap 'rm -rf "$task_temporary"' EXIT
mkdir -p "$task_root/.build/ui-module-cache" "$task_root/output/ui-review/layout"

python3 - "$task_root" "$task_temporary" "$@" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:3])
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
# The window regression uses the real SwiftUI App/WindowGroup sizing path, not
# the offscreen renderer (whose sizingOptions = [] masks constraint feedback).
if '--empty-library-window' in sys.argv:
    entry = (root / 'Sources/SwitchShelfApp/SwitchShelfApp.swift').read_text()
    entry = entry.replace('private var model = AppModel()', 'private var model = AppModel.emptyLibraryWindowFixture()')
    entry = entry.replace('await model.bootstrap()', 'await model.runEmptyLibraryWindowRegression()')
    entry = entry.replace('RootView(model: model)', 'RootView(model: model).defaultAppStorage(UserDefaults(suiteName: "local.switchshelf.ui-review.fixture")!).preferredColorScheme(CommandLine.arguments.contains("--dark") ? .dark : .light)')
    (temporary / 'SwitchShelfApp.swift').write_text(entry)
    (temporary / 'EmptyLibraryWindowRegression.swift').write_text(
        (root / 'scripts/verify-empty-library-window.swift').read_text())

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
if [[ " ${*} " != *" --empty-library-window "* ]]; then
    task_sources+=(scripts/verify-ui-layout.swift)
fi
task_modules="$task_root/.build/debug"
task_intermediates="$task_root/.build/out/Intermediates.noindex/SwitchShelf.build/Debug"

swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 \
  -module-cache-path "$task_root/.build/ui-module-cache" \
  -I "$task_modules" -I Sources/CSQLite \
  -Xcc "-fmodule-map-file=$task_intermediates/CDBIBridge-t.build/CDBIBridge.modulemap" \
  -Xcc "-fmodule-map-file=$task_intermediates/CDBIBackendUSB-t.build/CDBIBackendUSB.modulemap" \
  "${task_sources[@]}" \
  -L "$task_modules" -lSwitchShelfDomain -lSwitchShelfLibrary -lSwitchShelfDevice -lSwitchShelfBackend \
  "$task_modules/CDBIBridge.o" "$task_modules/CDBIBackendUSB.o" \
  -framework AppKit -framework SwiftUI -framework IOKit -framework ImageCaptureCore -lsqlite3 \
  -o "$task_temporary/SwitchShelfUIReview"

task_executable="$task_temporary/SwitchShelfUIReview"
if [[ " ${*} " == *" --empty-library-window "* ]]; then
    mkdir -p "$task_temporary/WindowRegression.app/Contents/MacOS"
    mv "$task_executable" "$task_temporary/WindowRegression.app/Contents/MacOS/WindowRegression"
    python3 - "$task_temporary/WindowRegression.app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'CFBundleIdentifier': 'local.switchshelf.window-regression',
                  'CFBundleExecutable': 'WindowRegression', 'CFBundlePackageType': 'APPL',
                  'CFBundleName': 'SwitchShelf window regression', 'LSMinimumSystemVersion': '26.0'}, f)
PY
    open -W -n "$task_temporary/WindowRegression.app" \
        --env "SWITCHSHELF_UI_REVIEW_STATE=$task_temporary/state" \
        --stdout "$task_temporary/window.out" --stderr "$task_temporary/window.err" --args "$@"
    python3 - "$task_temporary" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
print((root / 'window.out').read_text())
print((root / 'window.err').read_text())
sys.exit(0 if (root / 'state/window-regression-passed').exists() else 1)
PY
    exit $?
fi
SWITCHSHELF_UI_REVIEW_STATE="$task_temporary/state" \
  "$task_executable" "$task_root/output/ui-review/layout" "$task_temporary" "$@"
