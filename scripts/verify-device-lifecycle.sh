#!/bin/zsh
# Exercise current production AppModel against injected USB descriptors and fake
# probe executables. No bootstrap, hardware access, network, or source NAS reads.
set -euo pipefail
cd "${0:A:h:h}"
task_root="$PWD"
task_temporary="$(mktemp -d /private/tmp/switchshelf-device-lifecycle.XXXXXX)"
trap 'rm -rf "$task_temporary"' EXIT
mkdir -p "$task_root/.build/ui-module-cache"

python3 - "$task_root" "$task_temporary" <<'PY'
from pathlib import Path
import sys
root, temporary = map(Path, sys.argv[1:3])
for source in (root / 'Sources/SwitchShelfApp').glob('*.swift'):
    if source.name == 'SwitchShelfApp.swift':
        continue
    text = source.read_text()
    # Every preferences write belongs to an isolated suite, never the real app.
    text = text.replace('UserDefaults.standard',
                        'UserDefaults(suiteName: "local.switchshelf.device-lifecycle.fixture")!')
    if source.name == 'AppModel.swift':
        # External client presence and sound playback are fixture inputs only.
        text = text.replace('NSWorkspace.shared.runningApplications', '[NSRunningApplication]()')
        text = text.replace('NSSound(named: \"Hero\")?.play()', '()')
        text = text.replace('NSSound(named: \"Glass\")?.play()', '()')
        text += '\n' + (root / 'scripts/verify-device-lifecycle.swift').read_text()
    (temporary / source.name).write_text(text)
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
  -o "$task_temporary/DeviceLifecycleRegression"
"$task_temporary/DeviceLifecycleRegression" "$task_temporary"
