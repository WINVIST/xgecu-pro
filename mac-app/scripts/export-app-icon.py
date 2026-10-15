#!/usr/bin/env python3
"""Export the checked-in master into the macOS AppIcon asset catalog.

Developer-only dependency: Pillow (python -m pip install Pillow).
The checked-in exports let Xcode build without Python or Pillow.
"""

import json
from pathlib import Path

from PIL import Image


def main():
    app_root = Path(__file__).resolve().parents[1]
    master_path = app_root / "design" / "app-icon" / "XGecuPro-icon-1024.png"
    catalog = app_root / "XGecuPro" / "Assets.xcassets"
    destination = catalog / "AppIcon.appiconset"
    destination.mkdir(parents=True, exist_ok=True)

    with Image.open(master_path) as source:
        if source.size != (1024, 1024):
            raise ValueError("The app icon master must be 1024 x 1024 pixels")
        master = source.convert("RGBA")

    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            suffix = "@2x" if scale == 2 else ""
            filename = f"icon_{points}x{points}{suffix}.png"
            # Premultiplied alpha avoids dark fringes along transparent edges.
            icon = master.convert("RGBa").resize(
                (pixels, pixels), Image.Resampling.LANCZOS
            ).convert("RGBA")
            icon.save(destination / filename, optimize=True)
            images.append({
                "filename": filename,
                "idiom": "mac",
                "scale": f"{scale}x",
                "size": f"{points}x{points}",
            })

    metadata = {"info": {"author": "xcode", "version": 1}}
    (catalog / "Contents.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    (destination / "Contents.json").write_text(
        json.dumps({"images": images, **metadata}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Exported {len(images)} macOS app icon representations to {destination}")


if __name__ == "__main__":
    main()
