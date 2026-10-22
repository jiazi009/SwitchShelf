#!/usr/bin/env python3
"""Build a local native app bundle and include its libmtp runtime dependencies."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "-c", "release", "--product", "SwitchShelf"], cwd=ROOT, check=True)
bin_dir = Path(subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip())
app = ROOT / "build" / "SwitchShelf.app"
contents = app / "Contents"
macos = contents / "MacOS"
frameworks = contents / "Frameworks"
resources = contents / "Resources"
for directory in (macos, frameworks, resources):
    directory.mkdir(parents=True, exist_ok=True)
shutil.copy2(bin_dir / "SwitchShelf", macos / "SwitchShelf")
os.chmod(macos / "SwitchShelf", 0o755)
with (contents / "Info.plist").open("wb") as f:
    plistlib.dump({
        "CFBundleIdentifier": "local.switchshelf.app",
        "CFBundleName": "SwitchShelf", "CFBundleDisplayName": "SwitchShelf",
        "CFBundleExecutable": "SwitchShelf", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }, f)

copied = {}
def copy_library(source):
    source = source.resolve()
    if source in copied:
        return copied[source]
    target = frameworks / source.name
    shutil.copy2(source, target)
    os.chmod(target, 0o755)
    copied[source] = target
    dependencies = subprocess.check_output(["otool", "-L", str(source)], text=True).splitlines()[1:]
    subprocess.run(["install_name_tool", "-id", "@rpath/" + target.name, str(target)], check=True)
    for line in dependencies:
        old = line.strip().split(" (", 1)[0]
        dep = Path(old)
        if not dep.is_absolute() or not old.startswith(("/opt/homebrew/", "/usr/local/")):
            continue
        if dep.resolve() == source:
            continue
        new = copy_library(dep)
        subprocess.run(["install_name_tool", "-change", old, "@loader_path/" + new.name, str(target)], check=True)
    return target

mtp = next((p for p in (Path("/opt/homebrew/lib/libmtp.dylib"), Path("/usr/local/lib/libmtp.dylib")) if p.exists()), None)
if mtp:
    target = copy_library(mtp)
    alias = frameworks / "libmtp.dylib"
    if alias.is_symlink():
        alias.unlink()
    if not alias.exists():
        alias.symlink_to(target.name)
else:
    print("libmtp runtime not available: bundle will show an actionable device-read error.")

for target in copied.values():
    subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
