# XGecu Pro 1.2.0-beta.1

The first Windows 11 x64 and Linux x64 applications bring the macOS workflow
to matching Program, Hex Editor and Activity workspaces. macOS retains SwiftUI.

- T76 connection, SOIC16 suggestions, complete chip catalog and favorites.
- Firmware selection, private image/database snapshots, chip-ID preflight,
  explicit confirmation and programming with readback verification.
- Read twice, compare/verify, blank check, erase confirmation and USB diagnostics.
- File-backed BIN/Intel HEX/S-record editing up to 2 GiB: search, SHA-256,
  comparison, byte/range edits, copy/export and disk Undo/Redo.
- Light/dark appearance, keyboard shortcuts, native dialogs and unsaved-close protection.
- Windows per-user EXE installer; Ubuntu/Debian DEB and Linux AppImage.
  Separate macOS arm64 DMG/ZIP, setup guides and SHA-256 files are included.

**Preview status:** physical T76 chip operations have not been validated on
Windows or Linux. Software and packaged-app checks do not establish hardware
compatibility. See the verification record and existing macOS hardware record.

Windows requires WinUSB for the T76 interface. Driver setup is manual and may
affect vendor Xgpro; follow the setup/restoration guide. The Windows installer
is not Authenticode signed. Linux includes a T76-specific udev rule and must be
run as a normal desktop user. ARM64 is outside this preview.

No proprietary XGecu database or firmware is bundled. First use retrieves the
SHA-256-pinned database; subsequent launches can reuse its local cache offline.
The AppImage includes a separate libarchive-based extractor and its notices.

This port does not add the future BIOS/BMC roadmap features or partial-region
preservation. Erasable chips continue to use the existing whole-chip erase and
write/readback flow. Save the original dump before changing a chip.

[Installation and use](https://github.com/WINVIST/xgecu-pro/blob/main/desktop-app/README.md)
· [Verification](https://github.com/WINVIST/xgecu-pro/blob/main/desktop-app/VERIFICATION.md)
