#!/usr/bin/env python3
"""Build and verify the public drag-to-Applications DMG on macOS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time


DESIGN = Path(__file__).resolve().parents[1] / "design" / "dmg"


def read_layout():
    return json.loads((DESIGN / "layout.json").read_text(encoding="utf-8"))


def settings_for(app, layout):
    with (app / "Contents" / "Info.plist").open("rb") as source:
        metadata = plistlib.load(source)
    icon_name = Path(metadata["CFBundleIconFile"]).with_suffix(".icns").name
    icon = app / "Contents" / "Resources" / icon_name
    if not icon.is_file():
        raise ValueError(f"App icon is missing: {icon}")
    return {
        "format": "UDZO",
        "filesystem": "HFS+",
        "compression_level": 9,
        "files": [(str(app), layout["appName"])],
        "symlinks": {"Applications": "/Applications"},
        "hide_extensions": [layout["appName"]],
        "icon": str(icon),
        # dmgbuild combines this with background@2x.png into a Retina TIFF.
        "background": str(DESIGN / "background.png"),
        "window_rect": ((160, 160), (layout["width"], layout["height"])),
        "default_view": "icon-view",
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "show_icon_preview": False,
        "include_icon_view_settings": True,
        "include_list_view_settings": False,
        "arrange_by": None,
        "grid_spacing": 80,
        "scroll_position": (0, 0),
        "label_pos": "bottom",
        "text_size": layout["textSize"],
        "icon_size": layout["iconSize"],
        "icon_locations": {
            layout["appName"]: tuple(layout["appPosition"]),
            "Applications": tuple(layout["applicationsPosition"]),
        },
    }


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def detach(device):
    for attempt in range(4):
        result = subprocess.run(["/usr/bin/hdiutil", "detach", device])
        if result.returncode == 0:
            return
        if result.returncode != 16 or attempt == 3:
            result.check_returncode()
        time.sleep(2)


def verify_dmg(image, layout):
    from ds_store import DSStore

    run("/usr/bin/hdiutil", "verify", str(image))
    result = run(
        "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
        "-plist", str(image), stdout=subprocess.PIPE,
    )
    entities = plistlib.loads(result.stdout)["system-entities"]
    device = next(entity["dev-entry"] for entity in entities if "dev-entry" in entity)
    try:
        mount = Path(next(entity["mount-point"] for entity in entities if "mount-point" in entity))
        app = mount / layout["appName"]
        applications = mount / "Applications"
        if not applications.is_symlink() or os.readlink(applications) != "/Applications":
            raise ValueError("DMG does not contain the Applications drop link")
        if sorted(p.name for p in mount.iterdir() if not p.name.startswith(".")) != ["Applications", layout["appName"]]:
            raise ValueError("Unexpected visible items in the installation window")
        if not any(mount.glob(".background.*")):
            raise ValueError("DMG background is missing")
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            for name, position in (
                (layout["appName"], layout["appPosition"]),
                ("Applications", layout["applicationsPosition"]),
            ):
                if tuple(store[name]["Iloc"]) != tuple(position):
                    raise ValueError(f"Wrong Finder icon position for {name}")
            view = store["."]["icvp"]
            if view["backgroundType"] != 2 or view["iconSize"] != layout["iconSize"]:
                raise ValueError("Finder background or icon size was not preserved")
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
        # Exercise a copy out of the read-only image, as the user does in Finder.
        with tempfile.TemporaryDirectory(prefix="xgecu-dmg-copy-") as temporary:
            installed = Path(temporary) / layout["appName"]
            run("/usr/bin/ditto", str(app), str(installed))
            run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(installed))
            run(str(installed / "Contents" / "Resources" / "minipro"), "--version")
    finally:
        detach(device)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Built and signed XGecuPro.app")
    parser.add_argument("output", type=Path, help="New output .dmg path")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("DMG packaging requires macOS; the layout preview works on any OS")
    app = args.app.resolve()
    output = args.output.parent.resolve() / args.output.name
    checksum = output.with_name(output.name + ".sha256")
    if output.suffix != ".dmg":
        parser.error("Output must have the .dmg extension")
    if any(p.exists() or p.is_symlink() for p in (output, checksum)):
        parser.error("Output or checksum already exists; choose new paths")
    if not (app / "Contents" / "MacOS" / "XGecuPro").is_file():
        parser.error("Source is not a built XGecuPro application")
    if not (app / "Contents" / "Resources" / "minipro").is_file():
        parser.error("The bundled minipro helper is missing")
    if (app / "Contents" / "Resources" / "ChipDatabase").exists():
        parser.error("Public DMGs must not include a personal proprietary database")
    if app == output or app in output.parents:
        parser.error("Output must be outside the app bundle")
    for name in ("background.png", "background@2x.png"):
        if not (DESIGN / name).is_file():
            parser.error(f"Missing checked-in artwork: {name}")

    from dmgbuild import build_dmg

    layout = read_layout()
    settings = settings_for(app, layout)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="xgecu-dmg-", dir=output.parent) as temporary:
        candidate = Path(temporary) / output.name
        build_dmg(str(candidate), layout["volumeName"], settings=settings)
        verify_dmg(candidate, layout)
        # Publish the output only after mounting, layout and copied-app checks pass.
        with candidate.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        os.rename(candidate, output)
    checksum.write_text(f"{digest}  {output.name}\n", encoding="utf-8")
    print(f"Verified DMG: {output}")
    print(f"SHA-256: {checksum}")


if __name__ == "__main__":
    main()
