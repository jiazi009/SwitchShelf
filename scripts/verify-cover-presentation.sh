#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$task_root/.build/ui-review"
task_cache_dir="$task_root/.build/ui-module-cache"
mkdir -p "$task_build_dir" "$task_cache_dir"

CLANG_MODULE_CACHE_PATH="$task_cache_dir" xcrun swiftc \
    -swift-version 6 \
    -module-cache-path "$task_cache_dir" \
    "$task_root/Sources/SwitchShelfApp/CoverPalette.swift" \
    "$task_root/scripts/verify-cover-presentation.swift" \
    -o "$task_build_dir/verify-cover-presentation"

"$task_build_dir/verify-cover-presentation"
