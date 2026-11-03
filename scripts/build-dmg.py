#!/usr/bin/env python3
"""Build an ad-hoc signed, unnotarized arm64 DMG and its SHA-256 checksum."""
from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
build = ROOT / "build"
build.mkdir(exist_ok=True)

# A fresh staging bundle keeps old build products and local files out of the DMG.
with tempfile.TemporaryDirectory(prefix="SwitchShelf-release-", dir=build) as temporary:
    payload = Path(temporary) / "payload"
    app = payload / "SwitchShelf.app"
    subprocess.run([sys.executable, str(ROOT / "scripts" / "build-app.py"),
                    "--output", str(app)], cwd=ROOT, check=True)
    with (app / "Contents" / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    version = info["CFBundleShortVersionString"]
    notes = ROOT / "Docs" / "Releases" / f"v{version}.md"
    if not notes.is_file():
        raise SystemExit(f"Missing bilingual release notes: {notes}")

    for name in ("SwitchShelf", "switchshelf-probe"):
        executable = app / "Contents" / "MacOS" / name
        architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
        if architectures != ["arm64"]:
            raise SystemExit(f"Expected arm64 executable: {executable} ({architectures})")
    for library in (app / "Contents" / "Frameworks").glob("*.dylib"):
        architectures = subprocess.check_output(["lipo", "-archs", str(library)], text=True).split()
        if "arm64" not in architectures:
            raise SystemExit(f"Bundled library lacks arm64: {library}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)

    output = build / "releases" / f"v{version}"
    output.mkdir(parents=True, exist_ok=True)
    dmg = output / f"SwitchShelf-{version}-arm64.dmg"
    checksum = output / "SHA256SUMS"
    if dmg.exists() or checksum.exists():
        raise SystemExit(f"Release artifacts already exist in {output}; refusing to replace them.")

    (payload / "Applications").symlink_to("/Applications", target_is_directory=True)
    shutil.copyfile(notes, payload / "Read Me - 安装说明.txt")
    subprocess.run(["hdiutil", "create", "-volname", f"SwitchShelf {version}",
                    "-srcfolder", str(payload), "-fs", "HFS+", "-format", "UDZO", str(dmg)], check=True)
    subprocess.run(["hdiutil", "verify", str(dmg)], check=True)
    with dmg.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    checksum.write_text(f"{digest}  {dmg.name}\n", encoding="utf-8")
    print(f"DMG: {dmg}\nSHA-256: {checksum}\nSigning: ad-hoc; not notarized by Apple.")
