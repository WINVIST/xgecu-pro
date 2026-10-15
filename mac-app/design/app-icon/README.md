# XGecu Pro app icon

The mark combines a memory chip with a large blue X. The graphite tile,
silver contacts and simple face connect it to the app's hardware workflow
without relying on small text or circuit details.

`XGecuPro-icon-1024.png` is the transparent 1024-pixel master. It was created
for this project with the built-in OpenAI image generation tool; the exact
generation prompt is preserved in `prompt.txt`. No third-party stock image
or vendor artwork was used as an input.

The production exports are checked in at
`../../XGecuPro/Assets.xcassets/AppIcon.appiconset/`. The Xcode target compiles
that catalog with `AppIcon` selected in both Debug and Release. The macOS CI
workflow checks the resulting bundle's icon metadata and compiled `.icns`.

To regenerate the ten macOS representations after changing the master:

```sh
python3 -m pip install Pillow
python3 mac-app/scripts/export-app-icon.py
```

Run these commands from the repository root. Exporting only resizes the
master; Xcode and end users do not need Python or Pillow. The catalog covers
16, 32, 128, 256 and 512 points at 1x and 2x, including the 1024-pixel Retina
representation. Xcode generates the `.icns` while building on macOS.

The [DMG layout and packaging](../dmg/README.md) reuse the compiled app icon
as both the draggable app icon and the mounted volume icon.
