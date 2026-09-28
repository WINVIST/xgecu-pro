# XGecu Pro for macOS — implementation plan

Target: MacBook Pro M3, macOS 26.7, XGecu T76. The first milestone is a local,
unsigned SwiftUI app built from source on that Mac. Keep the existing Rust CLI
as the hardware backend and preserve its JSON interface so the GUI cannot
silently change programmer protocol behavior.

## 1. First usable build — implemented in source

- Create the fork and track upstream separately.
- Keep all interface text and project documentation in English.
- Build the Rust helper from the checked-in lockfile as part of the Xcode app.
- Show programmer identity, search and select chips, detect ID, read, save,
  preview, blank-check, compare with a file, write with dry-run and read-back
  verification, and erase.
- Serialize operations and require an explicit confirmation for destructive
  operations. Restrict them to the T76 and the parts already exercised on
  hardware upstream.
- Check chip identity before any erase or protection change. Bound imported
  images and network responses, and pin the default vendor archive checksum.

The source is complete, but this milestone is **not accepted** until the Xcode
build and the hardware checks below pass on the target Mac.
GitHub Actions also builds the app on a macOS 26 arm64 runner and runs the Rust
workspace tests; this catches compiler regressions but does not replace the
target-Mac and T76 acceptance steps.

## 2. Mac and T76 acceptance — requires the user's hardware

1. Build the Release scheme on macOS 26.7 with Xcode and Rust for
   `aarch64-apple-darwin`; resolve any SDK or Swift compiler errors.
2. Open the unsigned local app and verify T76 identity and a USB High Speed
   link through a USB 2.0 cable or hub.
3. Search the database, detect an inserted known part, read it twice, and
   compare the complete dumps with a separate tool.
4. Save a known-good original dump. On a disposable W27C512 or W27C257,
   exercise write, read-back comparison, erase, and blank check. Verify a
   deliberately wrong chip ID refuses mutation before erase.
5. Record the Mac model, macOS/Xcode/Rust versions, T76 firmware, database
   version, part and package, USB link, and results for reproducibility.

## 3. Closer parity with the original application

- Implemented in source: paged full-image hex buffer (64 MiB limit), file
  open/save, address jump, HEX and ASCII search, per-byte editing, range fill,
  block copy/export, undo/redo, SHA-256, and offline byte-for-byte file
  comparison. Buffer edits have Swift package tests in CI.
- Implemented in source: read-only chip database details for package, pin
  count, memory sizes, page size, electronic ID, and erased value.
- Add fuse/config/lock operations, multi-region memories, and
  package/socket diagrams when their CLI path and chip metadata are verified.
- Expand the supported T76 chip list one class at a time after hardware tests;
  add NAND/eMMC only with the proper adapters and recovery checks.
- Add diagnostics, batch workflows, and optional local release packaging after
  the core flows are reliable. Broader programmer families require their own
  hardware acceptance.

Keep feature scope and tested chip families in [README.md](README.md). The
backend's broader protocol roadmap remains in
[docs/rust-roadmap.md](../docs/rust-roadmap.md).

The original Xgpro workflow and buffer tools are described in the
[XGecu T48/T76 user guide](https://probots.co.in/technical_data/XGecu%20T48%20Universal%20Programmer__Guide.pdf).
