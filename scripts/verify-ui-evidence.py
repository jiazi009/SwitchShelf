#!/usr/bin/env python3
"""Reject stale UI screenshots, mismatched sources, missing states or clipped native geometry."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]
ACTUAL = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
          for p in sorted((ROOT / "Sources/SwitchShelfApp").glob("*.swift"))}


def inside(child, parent):
    return (child["width"] > 0 and child["height"] > 0
            and child["x"] >= parent["x"] - 1 and child["y"] >= parent["y"] - 1
            and child["x"] + child["width"] <= parent["x"] + parent["width"] + 1
            and child["y"] + child["height"] <= parent["y"] + parent["height"] + 1)


def image_hash(directory, name, expected):
    path = directory / name
    assert path.is_file(), f"Missing screenshot: {path}"
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, f"Stale image: {path}"


layout = ROOT / "output/ui-review/layout"
manifest = json.loads((layout / "manifest.json").read_text())
assert manifest["productionSourceSHA256"] == ACTUAL, "Offscreen captures do not match current production sources"
assert len(manifest["captures"]) == 24
for capture in manifest["captures"]:
    image_hash(layout, capture["name"] + ".png", capture["imageSHA256"])

states = ["empty", "populated-grid", "populated-list", "ambiguous-expanded"]
sizes = ["960x640", "1280x820", "1516x809", "1276x1410"]
expected_matrix = {f"{state}-{size}" for state in states for size in sizes}
images = 0
for variant in ["light-animated", "dark-animated", "light-reduced", "dark-reduced"]:
    directory = ROOT / "output/ui-review/native-staging" / variant
    manifest = json.loads((directory / "manifest.json").read_text())
    assert manifest["passed"] and manifest["fixtureOnly"] and manifest["noBootstrapUSBOrInstallation"]
    assert manifest["productionSourceSHA256"] == ACTUAL, f"Stale native source fingerprint: {variant}"
    entries = {entry["name"]: entry for entry in manifest["entries"]}
    assert expected_matrix <= entries.keys(), f"Missing state/size coverage: {variant}"
    for name in expected_matrix:
        entry = entries[name]
        frames, viewport = entry["checkedFrames"], entry["viewport"]
        assert all(inside(rect, viewport) for rect in frames.values()), f"Native clipping: {variant}/{name}"
        assert abs(frames["staging"]["width"] - 320) < 1
        assert inside(frames["installButton"], frames["staging"])
        if name.startswith("populated"):
            assert entry["stagedGames"] == 2 and entry["libraryGames"] == 5
            for game in ["matrix-1", "matrix-2"]:
                assert inside(frames[f"staged-card-{game}"], frames["stagingViewport"])
                assert inside(frames[f"staged-title-{game}"], frames[f"staged-card-{game}"])
                assert inside(frames[f"remove-staged-{game}"], frames[f"staged-card-{game}"])
        if name.startswith("empty"):
            assert entry["stagedGames"] == 0 and entry["libraryGames"] == 0
    # Installation starts immediately in the current app; real sends are never
    # triggered by this synthetic window suite. Lifecycle/physical tests cover it.
    assert {"details-grid", "details-list"} <= entries.keys()
    for entry in entries.values():
        if "image" in entry:
            image_hash(directory, entry["image"], entry["imageSHA256"])
            images += 1
print(f"PASS: 24 current-source layout images; 64 native state/size cases; {images} native content snapshots; source/image hashes and x/y bounds verified.")
