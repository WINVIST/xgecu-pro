XGecu Pro 1.1.1 adds a native drag-to-Applications installation experience.

- A new graphite memory-chip icon with a blue X appears in Finder, Dock and
  the installation window.
- The DMG opens a clear two-item layout: drag XGecuPro onto Applications,
  then launch the installed copy. The background includes Retina artwork.
- Releases include both DMG and ZIP downloads with individual SHA-256 files.
- The installation screen shows first-launch signature/quarantine commands
  for this ad hoc build; a separate text download makes them easy to copy.
- macOS CI verifies the disk image, saved Finder layout, Applications link,
  app signatures and a copied-out app with its bundled CLI before publishing.

Requires Apple Silicon and macOS 26 or later. The app and helper are ad hoc
signed; this release has no Developer ID signature or Apple notarization.
Verify the downloaded checksum and follow the
[installation guide](https://github.com/WINVIST/xgecu-pro/blob/v1.1.1/mac-app/README.md#install-a-prebuilt-ci-app)
for first-open verification and Gatekeeper instructions.

Vendor databases, firmware and proprietary algorithms are not bundled in
public downloads. Database retrieval and hardware support are unchanged from
1.1.0; this is an application identity and distribution update.
