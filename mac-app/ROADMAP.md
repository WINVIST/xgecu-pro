# XGecu Pro for macOS — implementation plan

Target: MacBook Pro M3, macOS 26.7, XGecu T76. The first milestone is an
ad hoc signed SwiftUI app built on macOS CI for installation on that Mac; a local
source build remains available. Keep the existing Rust CLI as the hardware
backend and preserve its JSON interface so the GUI cannot
silently change programmer protocol behavior.

## 1. First usable build — implemented in source

- Create the fork and track upstream separately.
- Keep all interface text and project documentation in English.
- Build the Rust helper from the checked-in lockfile as part of the Xcode app.
- Publish an ad hoc signed Apple Silicon app archive from successful macOS CI runs
  so the target Mac can install it without a local Xcode or Rust build.
- Show programmer identity, search and select chips, detect ID, read, save,
  preview, blank-check, compare with a file, write with dry-run and read-back
  verification, and erase.
- Suggest either requested Macronix SOIC16 database entry from a T76 JEDEC
  autodetect result while keeping unsupported IDs and mutation disabled.
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

Follow the [target-Mac validation checklist](HARDWARE-VALIDATION.md) and retain
the recorded results with the original dumps.

1. Install the successful CI archive on macOS 26.7, or build the Release scheme
   locally with Xcode and Rust for `aarch64-apple-darwin`; resolve any install,
   SDK, or Swift compiler errors on the target Mac. If a management profile
   prevents per-app Gatekeeper exceptions, installation also requires an
   administrator-approved or Developer ID signed and notarized build.
2. Test the supplied USB cable directly on the target Mac and record the
   negotiated link speed in macOS System Information (USB) and the result of
   the app's **Connect / Refresh** action. If it negotiates SuperSpeed,
   capture the diagnostic before testing a USB 2.0 cable
   or hub as the known High Speed fallback. Do not run chip operations on an
   unresponsive SuperSpeed link.
3. Search the database, detect an inserted known part, read it twice, and
   compare the complete dumps with a separate tool.
4. Save a known-good original dump. On a disposable W27C512 or W27C257,
   exercise write, read-back comparison, erase, and blank check. Verify a
   deliberately wrong chip ID refuses mutation before erase.
5. Record the Mac model, macOS/Xcode/Rust versions, T76 firmware, database
   version, part and package, USB link, and results for reproducibility.

### User-requested hardware support

- Support `MX25L51245GMI-10G` (512 Mbit / 64 MiB) and
  `MX25L25645GMI-08G` (256 Mbit / 32 MiB), as confirmed by the user. Both
  are 2.7–3.6 V Macronix 16-SOP (300 mil) serial NOR parts according to their
  [51245G](https://www.macronix.com/Lists/Datasheet/Attachments/9100/MX25L51245G%2C%203V%2C%20512Mb%2C%20v1.8.pdf)
  and [25645G](https://www.macronix.com/Lists/Datasheet/Attachments/8906/MX25L25645G%2C%203V%2C%20256Mb%2C%20v2.0.pdf)
  datasheets. The pinned T76 V13.21 database contains `MX25L51245G@SOIC16`
  (64 MiB, ID `C2201A`) and `MX25L25645G@SOIC16` (32 MiB, ID `C22019`);
  the GUI now permits read-only operations when those details match. Validate
  the T76 algorithm and socket or adapter placement, read each chip twice,
  compare complete dumps, and retain
  original backups. Enable writing or erase only after successful tests on
  disposable examples.
- Support the supplied USB cable on the MacBook Pro M3. Record whether it
  negotiates High Speed or SuperSpeed. High Speed can be accepted through the
  existing backend after live tests. The current macOS SuperSpeed path fails
  on T76 bulk transfers and is blocked with a diagnostic; it needs a
  demonstrated firmware/host/hub workaround and repeated live transfers
  before it can be marked supported. The USB 2.0 fallback does not require a
  different programmer or an ISP connection.

## 3. Additional tools already in source

- Implemented in source: paged full-image hex buffer (64 MiB limit), file
  open/save for raw, Intel HEX, and S-record images, address jump, HEX and ASCII
  search, per-byte editing, range fill,
  block copy/export, undo/redo, SHA-256, and offline byte-for-byte file
  comparison. Buffer edits have Swift package tests in CI.
- Implemented in source: read-only chip database details for package, pin
  count, memory sizes, page size, electronic ID, and erased value.

## 4. Optional backlog — wait for the user's decision

- Fuse/config/lock operations, multi-region memories, and package/socket
  diagrams after their CLI path and chip metadata are verified.
- Expand the supported T76 chip list beyond the two requested Macronix parts
  one class at a time after hardware tests;
  NAND/eMMC require the proper adapters and recovery checks.
- Diagnostics, batch workflows, and Developer ID signing/notarization for
  frictionless distribution after the core flows are reliable. Broader
  programmer families require their own
  hardware acceptance.

Keep feature scope and tested chip families in [README.md](README.md). The
backend's broader protocol roadmap remains in
[docs/rust-roadmap.md](../docs/rust-roadmap.md).

The original Xgpro workflow and buffer tools are described in the
[XGecu T48/T76 user guide](https://probots.co.in/technical_data/XGecu%20T48%20Universal%20Programmer__Guide.pdf).
