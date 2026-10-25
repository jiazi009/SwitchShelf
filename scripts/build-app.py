#!/usr/bin/env python3
"""Build a local native app bundle and include its libmtp runtime dependencies."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--with-libmtp", action="store_true", help="Bundle optional libmtp fallback and its native dependencies")
parser.add_argument("--icon", type=Path, help="Selected PNG app icon; otherwise use Assets/AppIcon.png if present")
args = parser.parse_args()
icon = args.icon or ROOT / "Assets" / "AppIcon.png"
if args.icon and not icon.is_file():
    parser.error(f"Icon does not exist: {icon}")
subprocess.run(["swift", "build", "-c", "release", "--product", "SwitchShelf"], cwd=ROOT, check=True)
subprocess.run(["swift", "build", "-c", "release", "--product", "switchshelf-probe"], cwd=ROOT, check=True)
bin_dir = Path(subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT, text=True).strip())
app = ROOT / "build" / "SwitchShelf.app"
contents = app / "Contents"
macos = contents / "MacOS"
frameworks = contents / "Frameworks"
resources = contents / "Resources"
for directory in (macos, frameworks, resources):
    directory.mkdir(parents=True, exist_ok=True)
for executable in ("SwitchShelf", "switchshelf-probe"):
    shutil.copy2(bin_dir / executable, macos / executable)
    os.chmod(macos / executable, 0o755)
icon_info = {}
if not icon.is_file():
    (resources / "AppIcon.icns").unlink(missing_ok=True)  # Do not retain a previously selected icon.
if icon.is_file():
    with tempfile.TemporaryDirectory(prefix="SwitchShelf-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = size * scale
                name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
                subprocess.run(["sips", "-z", str(pixels), str(pixels), str(icon),
                                "--out", str(iconset / name)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns")], check=True)
    icon_info["CFBundleIconFile"] = "AppIcon"
with (contents / "Info.plist").open("wb") as f:
    plistlib.dump({
        "CFBundleIdentifier": "local.switchshelf.app",
        "CFBundleName": "SwitchShelf", "CFBundleDisplayName": "SwitchShelf",
        "CFBundleExecutable": "SwitchShelf", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
        "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
        **icon_info,
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

mtp = next((p for p in (Path("/opt/homebrew/lib/libmtp.dylib"), Path("/usr/local/lib/libmtp.dylib")) if p.exists()), None) if args.with_libmtp else None
if mtp:
    target = copy_library(mtp)
    alias = frameworks / "libmtp.dylib"
    if alias.is_symlink():
        alias.unlink()
    if not alias.exists():
        alias.symlink_to(target.name)
elif args.with_libmtp:
    print("libmtp runtime not available: bundle will show an actionable device-read error.")

for target in copied.values():
    subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
print(app)
