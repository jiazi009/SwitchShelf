#!/usr/bin/env python3
"""Smoke-test the real probe runtime without opening a USB/MTP session.

Usage: python3 scripts/verify-probe-runtime.py [path/to/switchshelf-probe]
Run against the debug and release probe after building. Discovery only reads
IOKit descriptors; inventory commands below are rejected before worker launch.
This complements fake-process tests, which cannot exercise Swift actor checks
in the executable's actual parent watcher and worker entry point.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
probe = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".build/release/switchshelf-probe"
probe = probe.resolve(strict=True)

def run(*arguments, environment=None):
    result = subprocess.run([str(probe), *arguments], capture_output=True, text=True,
                            timeout=15, env=environment)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"Probe emitted invalid JSON (exit {result.returncode})") from error
    return result.returncode, value

for _ in range(10):
    code, value = run("discover", "--timeout", "5", "--json")
    assert code == 0 and value.get("mode") == "discover" and value.get("status") == "ok", value
    assert "inventory" not in value and isinstance(value.get("discovery"), dict), value
print("PASS: 10 real supervisor/worker discovery launches; no MTP session opened")

for route in ("native", "libmtp"):
    code, value = run("inventory", "--transport", route, "--json")
    assert code == 64 and value.get("error", {}).get("code") == "usage", value
print("PASS: retired routes rejected before USB worker launch")

with tempfile.TemporaryDirectory(prefix="switchshelf-cancel-protocol-") as directory:
    marker = Path(directory) / "cancel"
    marker.write_bytes(b"")
    environment = dict(os.environ, SWITCHSHELF_PROBE_CANCEL_PATH=str(marker))
    code, value = run("inventory", "--json", environment=environment)
    assert code == 1 and value.get("transport") == "libusb", value
    assert value.get("error", {}).get("code") == "cancelled", value
    assert "before worker launch" in value["error"]["message"], value
print("PASS: preexisting cancellation prevents the inventory worker from launching")

linked = subprocess.check_output(["otool", "-L", str(probe)], text=True)
assert "ImageCaptureCore" not in linked
print("PASS: executable has no ImageCaptureCore linkage")
