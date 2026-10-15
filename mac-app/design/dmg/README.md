# Drag-to-Applications installation

## Design contract

This is a fixed 720 x 460 point Finder content area. Its job is to explain
one action: copy `XGecuPro.app` to Applications. The app icon on the left and
the real `/Applications` symlink on the right remain native Finder items,
including their labels and keyboard selection. The arrow, heading and short
instructions are artwork, not controls. The footer explains where to launch
the installed copy.

The existing blue X / graphite chip icon is the product reference. A light
neutral background gives the two icons space and keeps the instructions
readable. No network content, account, purchase flow, animation or installer
wizard is part of this window. All app-facing text remains English.

`layout.json` defines icon coordinates, window dimensions and text sizes for
packaging. `background.svg` is the editable artwork; the checked-in PNGs are
720 x 460 at 72 dpi and 1440 x 920 at 144 dpi. The images intentionally contain
neither app nor folder icons: both must remain draggable in Finder.

`preview.html` is a static design preview, not an installer. Its folder drawing
and titlebar are schematic; the real window uses the user's native macOS
appearance. The preview also scales on narrow browsers; Finder itself uses
the fixed layout. Test targets are 1280 x 720 and 390 x 844 for the preview.

Loading, empty, error, partial, success and permission states are not states of
the static artwork. In the real installation, Finder owns copying progress,
replacement prompts and filesystem errors. Gatekeeper owns the first-open
security decision. Those native interactions need a target-Mac check, not
simulated success messages in a preview.

## Build the real DMG on macOS

Use Python 3.11 or later, with a built and code-signed app:

```sh
python3 -m venv /tmp/xgecu-dmg-venv
/tmp/xgecu-dmg-venv/bin/python -m pip install -r mac-app/scripts/requirements-dmg.txt
/tmp/xgecu-dmg-venv/bin/python mac-app/scripts/build-dmg.py \
  /path/to/XGecuPro.app /path/to/XGecuPro-macOS-arm64.dmg
```

The build uses MIT-licensed [dmgbuild 1.6.7](https://pypi.org/project/dmgbuild/1.6.7/).
Its [settings API](https://dmgbuild.readthedocs.io/en/latest/settings.html)
writes the Finder layout without a GUI scripting session. It combines the
1x and 2x PNGs into a multi-resolution TIFF, uses the app icon for the volume,
and creates a compressed, read-only image.

Before publishing an output file, the script verifies the image, mounts it
read-only, checks the Applications link, visible contents, background and
stored icon positions, verifies the app signature, copies the app to a temporary
directory and checks that copy and its bundled CLI. It detaches the image in
a finally block. The script refuses existing outputs and personal offline
apps with a bundled proprietary database.

CI runs this packaging check after the existing app build, and uploads the
DMG, ZIP and both checksum files. Tagged releases publish both formats. The
DMG does not change the app's signing or notarization status.

To regenerate the artwork, make `sharp` available to Node and run:

```sh
node mac-app/scripts/render-dmg-artwork.cjs
```

Node and sharp are only needed when editing the artwork, not to build the
DMG from the checked-in PNGs. The SVG and preview folder drawing are original
project artwork; no stock asset, downloaded font or external service is used.

## Target-Mac acceptance

The Windows checkout can verify artwork and configuration, but cannot run
`hdiutil`, inspect real Finder rendering or confirm Gatekeeper behavior.
Before publishing a release:

- Build with the macOS CI workflow and inspect its packaging result.
- Open the downloaded DMG on macOS 26 in light and dark appearance, including
  Retina. Confirm that opening the image shows the expected two-item layout,
  labels remain readable, no scrollbars obscure the instructions, and all
  artwork is aligned with the native icons.
- Select and copy the app using both mouse and keyboard, eject the volume,
  then launch the installed copy from Applications. On an existing installation,
  check Finder's replacement prompt rather than adding a custom overwrite flow.
- Confirm that the current ad hoc build still follows the documented
  Gatekeeper verification steps. Developer ID and notarization remain separate.

Local preview evidence is stored beside this document. It does not certify
the native installation or the macOS CI job.
