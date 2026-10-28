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
        detailGameID = nil
        selectedGameIDs.removeAll()
        activeGameID = nil
        notice = nil
        cacheLoaded = true
        isBootstrapped = true
        deviceDiscovery = DeviceDiscovery(state: .disconnected, message: "UI fixture：未连接任何真实设备；不会执行 USB 枚举。")
        if inspector, let game = snapshot.games.first {
            selectedGameIDs = [game.id]
            activeGameID = game.id
        }
    }
    func seedUIReviewDevice(_ value: DeviceDiscovery) { deviceDiscovery = value }
}
'''
if '--selection-baseline' in sys.argv:
    # Diagnostic-only A/B: reproduce the old unconditional sort in the fixture.
    model = model.replace('let ordered = flags.contains(.shift) ? filteredGames.map(\\.id) : []',
                          'let ordered = filteredGames.map(\\.id)')
(temporary / 'AppModel.swift').write_text(model)
# The window regression uses the real SwiftUI App/WindowGroup sizing path, not
# the offscreen renderer (whose sizingOptions = [] masks constraint feedback).
if '--empty-library-window' in sys.argv:
    entry = (root / 'Sources/SwitchShelfApp/SwitchShelfApp.swift').read_text()
    entry = entry.replace('private var model = AppModel()', 'private var model = AppModel.emptyLibraryWindowFixture()')
    entry = entry.replace('await model.bootstrap()', 'await model.runEmptyLibraryWindowRegression()')
    entry = entry.replace('RootView(model: model)', 'RootView(model: model).defaultAppStorage(UserDefaults(suiteName: "local.switchshelf.ui-review.fixture")!).preferredColorScheme(CommandLine.arguments.contains("--dark") ? .dark : .light).environment(\\.installationAnimationsEnabled, !CommandLine.arguments.contains("--reduce-motion"))')
    (temporary / 'SwitchShelfApp.swift').write_text(entry)
    (temporary / 'EmptyLibraryWindowRegression.swift').write_text(
        (root / 'scripts/verify-empty-library-window.swift').read_text())
    (temporary / 'InstallStagingRegression.swift').write_text(
        (root / 'scripts/verify-install-staging.swift').read_text())
    (temporary / 'StagingWindowEvidence.swift').write_text(
        (root / 'scripts/verify-staging-window-evidence.swift').read_text())
    sidebar = (temporary / 'InstallationSidebar.swift').read_text()
    for identifier, key in [('begin-staged-installation', 'installButton'), ('installation-sidebar', 'staging'), ('staging-viewport', 'stagingViewport')]:
        anchor = '.accessibilityIdentifier("' + identifier + '")'
        sidebar = sidebar.replace(anchor, anchor + '\n'
            '        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {\n'
            '            WindowLayoutEvidence.frames["' + key + '"] = $0\n'
            '        }')
    for prefix, key in [('staging-cover', 'staging-cover'), ('staged-game', 'staged-card'), ('staged-title', 'staged-title'), ('remove-staged', 'remove-staged')]:
        identifier = prefix + r'-\(item.gameID)'
        key = key + r'-\(item.gameID)'
        anchor = '.accessibilityIdentifier("' + identifier + '")'
        sidebar = sidebar.replace(anchor, anchor + '\n'
            '        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {\n'
            '            WindowLayoutEvidence.frames["' + key + '"] = $0\n'
            '        }')
    (temporary / 'InstallationSidebar.swift').write_text(sidebar)
    for filename, identifier, key in [
        ('GameInteraction.swift', r'game-details-\(placement.rawValue)-\(game.id)', r'details-\(placement.rawValue)-\(game.id)'),
        ('InspectorView.swift', 'close-game-details', 'details-close')]:
        source = (temporary / filename).read_text()
        anchor = '.accessibilityIdentifier("' + identifier + '")'
        source = source.replace(anchor, anchor + '\n'
            '        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {\n'
            '            WindowLayoutEvidence.frames["' + key + '"] = $0\n'
            '        }')
        (temporary / filename).write_text(source)
    for filename, anchor in [('SidebarView.swift', 'brand'), ('LibraryView.swift', 'header')]:
        source = (temporary / filename).read_text()
        source = source.replace('            ' + anchor + '\n', '            ' + anchor + '\n'
            '                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {\n'
            '                    WindowLayoutEvidence.frames["' + anchor + '"] = $0\n'
            '                }\n', 1)
        (temporary / filename).write_text(source)

    library = (temporary / 'LibraryView.swift').read_text()
    for label, key in [('游戏封面网格', 'gridViewport'), ('游戏列表', 'listViewport')]:
        anchor = '.accessibilityLabel("' + label + '")'
        library = library.replace(anchor, anchor + '\n'
            '        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {\n'
            '            WindowLayoutEvidence.frames["' + key + '"] = $0\n'
            '        }')
    (temporary / 'LibraryView.swift').write_text(library)

game = (root / 'Sources/SwitchShelfApp/GameViews.swift').read_text()
game = game.replace(
    'directory: (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first\n'
    '            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))\n'
    '            .appendingPathComponent("SwitchShelf/CoverThumbnails", isDirectory: true)',
    'directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHSHELF_UI_REVIEW_STATE"]!, isDirectory: true)'
    '.appendingPathComponent("CoverThumbnails", isDirectory: true)')
if '--empty-library-window' in sys.argv:
    for identifier, key in [(r'game-card-\(game.id)', r'card-\(game.id)'), (r'game-row-\(game.id)', r'row-\(game.id)'), (r'library-cover-grid-\(game.id)', r'library-cover-grid-\(game.id)'), (r'library-cover-list-\(game.id)', r'library-cover-list-\(game.id)'), (r'library-bytes-\(game.id)', r'library-bytes-\(game.id)')]:
        anchor = '.accessibilityIdentifier("' + identifier + '")'
        game = game.replace(anchor, anchor + '\n'
            '        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {\n'
            '            WindowLayoutEvidence.frames["' + key + '"] = $0\n'
            '        }')
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
  -framework AppKit -framework SwiftUI -framework IOKit -lsqlite3 \
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
    codesign --force --sign - "$task_temporary/WindowRegression.app" >/dev/null 2>&1
    # A failed or skipped capture must not inherit a previous passing manifest.
    python3 - "$task_root" "$@" <<'PY'
from pathlib import Path
import sys
variant = ('dark' if '--dark' in sys.argv else 'light') + ('-reduced' if '--reduce-motion' in sys.argv else '-animated')
directory = Path(sys.argv[1]) / 'output/ui-review/native-staging' / variant
directory.mkdir(parents=True, exist_ok=True)
for pattern in ('*.json', '*.png'):
    for path in directory.glob(pattern):
        path.unlink()
PY
    open -W -n "$task_temporary/WindowRegression.app" \
        --env "SWITCHSHELF_UI_REVIEW_STATE=$task_temporary/state" \
        --env "SWITCHSHELF_NATIVE_EVIDENCE=$task_root/output/ui-review/native-staging" \
        --stdout "$task_temporary/window.out" --stderr "$task_temporary/window.err" --args "$@"
    python3 - "$task_temporary" "$task_root" "$@" <<'PY'
from pathlib import Path
import sys, hashlib, json
root, project = map(Path, sys.argv[1:3])
print((root / 'window.out').read_text())
print((root / 'window.err').read_text())
passed = (root / 'state/window-regression-passed').exists()
variant = ('dark' if '--dark' in sys.argv else 'light') + ('-reduced' if '--reduce-motion' in sys.argv else '-animated')
evidence = project / 'output/ui-review/native-staging' / variant
if passed:
    rows = [json.loads(p.read_text()) for p in sorted(evidence.glob('*.json')) if p.name != 'manifest.json']
    manifest = {'fixtureOnly': True, 'passed': True, 'variant': variant,
                'productionSourceSHA256': {str(p.relative_to(project)): hashlib.sha256(p.read_bytes()).hexdigest()
                                          for p in sorted((project / 'Sources/SwitchShelfApp').glob('*.swift'))},
                'captureMethod': 'active native production WindowGroup content snapshots; not desktop screenshots',
                'geometryChecks': 'both axes, populated and empty, native scrolling viewports',
                'noBootstrapUSBOrInstallation': True, 'entries': rows}
    (evidence / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
sys.exit(0 if passed else 1)
PY
    exit $?
fi
SWITCHSHELF_UI_REVIEW_STATE="$task_temporary/state" \
  "$task_executable" "$task_root/output/ui-review/layout" "$task_temporary" "$@"
if [[ " ${*} " != *" --live-dark "* ]]; then
python3 - "$task_root" <<'PY'
from pathlib import Path
import hashlib, json, sys
root = Path(sys.argv[1])
path = root / 'output/ui-review/layout/manifest.json'
manifest = json.loads(path.read_text())
manifest['productionSourceSHA256'] = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                     for p in sorted((root / 'Sources/SwitchShelfApp').glob('*.swift'))}
for capture in manifest['captures']:
    capture['imageSHA256'] = hashlib.sha256((path.parent / (capture['name'] + '.png')).read_bytes()).hexdigest()
path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
PY
fi
