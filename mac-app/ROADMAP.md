# XGecu Pro for macOS — implementation plan

Target: MacBook Pro M3, macOS 26.7, XGecu T76. The first milestone is an
ad hoc signed SwiftUI app built on macOS CI for installation on that Mac; a local
source build remains available. Keep the existing Rust CLI as the hardware
backend and preserve its JSON interface so the GUI cannot
silently change programmer protocol behavior.

## Current priority — usability before more features (2026-10-15)

The primary user workflow is: seat a chip, select its exact database entry,
choose a firmware binary, and program it with readback verification.

- First iteration: a dedicated Program workspace with explicit Chip,
  Firmware, and Program and Verify steps; selected file name and path;
  readiness guidance and a persistent operation status area.
- Keep chip reading, file comparison, blank check, and erase available as
  secondary tools. Put hex editing and operation history in their own tabs.
- Keep preflight, chip-ID checks, private image snapshots, confirmation,
  and backend readback verification. Programming uses the chosen file;
  unsaved hex-buffer edits must be saved first.
- Build and test on the existing GitHub macOS runner, capture native SwiftUI
  display fixtures in light/dark and compact windows, and provide a branch
  app artifact for target-Mac review. Fixture screenshots are not hardware
  acceptance or a complete accessibility test.
- After this workflow is reviewed on the target Mac, continue with the
  full catalog and favorites, then file-backed buffers and streaming.

The user authorized continuing the complete primary roadmap on 2026-10-15.
Catalog and favorites are implemented and verified on macOS CI: complete database
browsing, live name/package filtering, persisted favorites at the top of
the picker, and metadata lookup before chip operations. File-backed buffers
and streamed conversion, read, verification and programming are also
implemented and macOS CI-verified. The editor's catalog-size check exercises
1,140,850,688 bytes, including paging, edit/undo, SHA-256 and file comparison.
A read-only Check Setup tool also reports chip ID and actual contact-test
availability. Per-family physical acceptance remains separate.

See [the usability iteration](UX-ITERATION.md) for the design rationale and
target-Mac review checklist.

## 1. First usable build — implemented in source

- Create the fork and track upstream separately.
- Keep all interface text and project documentation in English.
- Build the Rust helper from the checked-in lockfile as part of the Xcode app.
- Publish an ad hoc signed Apple Silicon app archive from successful macOS CI runs
  so the target Mac can install it without a local Xcode or Rust build.
- Show programmer identity, search and select chips, detect ID, read, save,
  preview, blank-check, compare with a file, write with dry-run and read-back
  verification, and erase.
- Suggest all SOIC16 database entries matching a T76 JEDEC autodetect result.
  Require the user to confirm the printed part marking when multiple entries
  share an ID.
- Serialize operations and require an explicit confirmation for destructive
  operations. Use the entire database on a connected T76, subject to backend
  image limits, electronic ID checks, and erase capability.
- Check chip identity before any erase or protection change. Bound imported
  images and network responses, and pin the default vendor archive checksum.

The macOS 26 arm64 CI build and core target-Mac T76 read flow have passed.
The user confirmed direct supplied-cable operation, repeated reads of both
priority chips, and a verified MX66 code-region program. Remaining chip
families and destructive operations still need their own hardware checks.

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

- Prioritize the two chips confirmed by photographs: `MX66L1G45GMI-08G`
  (1 Gbit / 128 MiB) and `MX25L51245GMI-08G` (512 Mbit / 64 MiB). Both are
  2.7–3.6 V Macronix 16-SOP (300 mil) serial NOR parts according to their
  [1 Gbit](https://www.macronix.com/Lists/Datasheet/Attachments/8734/MX66L1G45G%2C%25203V%2C%25201Gb%2C%2520v1.5.pdf)
  and [512 Mbit](https://www.macronix.com/Lists/Datasheet/Attachments/9100/MX25L51245G%2C%203V%2C%20512Mb%2C%20v1.8.pdf)
  datasheets. The pinned T76 V13.21 database contains `MX66L1G45G@SOIC16`
  (128 MiB, ID `C2201B`) and `MX25L51245G@SOIC16` (64 MiB, ID `C2201A`).
  The GUI exposes database-driven operations for both. On the target Mac, the
  MX66L1G45G code region was programmed with backend readback verification;
  two subsequent full 128 MiB dumps matched by SHA-256 and external `cmp`.
  The MX25L51245G code region was read twice at 64 MiB; the dumps matched by
  SHA-256 and external `cmp`, and Verify Against File reported a match. Build 9
  also received a user-reported MX25 Program and Verify pass through UGREEN;
  standalone erase/blank check remains untested. The original MX66 pre-program backup remains
  unconfirmed. Retain original backups before destructive actions on
  disposable examples. Earlier provisional
  `MX25L25645GMI-08G` support is not part of this acceptance target.
- Support the supplied USB cable on the MacBook Pro M3. The user confirmed a
  direct connection with this cable at USB High Speed, including T76 detection
  and repeated full reads of the MX66L1G45G. Build 8 fixes the observed missing
  interface/GET_CONFIGURATION STALL on Wavlink. The user confirmed a full 64 MiB
  MX25L51245G comparison over USB SuperSpeed against the Digma-route dump.
  Build 9 enables chip programming/erase with existing ID/readback checks;
  the user subsequently reported a programming/readback pass through UGREEN.
  Wavlink programming, standalone erase/blank check, direct USB3 and repeated
  cold-connect acceptance remain pending. Programmer firmware updates still require USB2 on macOS T76.
  The USB 2.0 fallback does not require a different programmer or ISP connection.

## 3. Additional tools already in source

- Implemented in source: file-backed paged hex buffer (2 GiB decoded limit), file
  open/save for raw, Intel HEX, and S-record images, address jump, HEX and ASCII
  search, per-byte editing, range fill,
  block copy/export, undo/redo, SHA-256, and offline byte-for-byte file
  comparison. Buffer edits have Swift package tests in CI.
- Implemented in source: read-only chip database details for package, pin
  count, memory sizes, page size, electronic ID, and erased value.

## 4. Requested after basic hardware acceptance

- Implemented and CI-verified: complete catalog browsing, live name/package
  search and persisted favorites at the top of the picker. The pinned T76
  V13.21 catalog test retrieves all 33,612 entries. Favorites are separate
  from hardware-validated read/write support.
- Implemented and CI-verified: file-backed paged buffers and streamed raw,
  Intel HEX and S-record conversion, read, verification and programming up
  to 2 GiB decoded. Private spools, block-wise comparison and disk-backed edit
  history avoid retaining full images in RAM. The pinned catalog contains code
  regions up to 1,140,850,688 bytes (`S34ML08G201Txx00@TSOP48`, including NAND
  spare area). At that size the converter and editor passed content checks
  with about 6.6 MiB and 7.2 MiB maximum resident memory respectively. This is
  a sizing test; NAND algorithms and adapters require physical acceptance.

## 5. Optional backlog — wait for the user's decision

- A script now makes a private offline app from an owner-supplied extracted
  database and an already-built app. Public builds download and verify the
  vendor archive once, then reuse the extracted local cache. Do not include
  the proprietary vendor DLL or FPGA algorithms in a public GitHub Release
  without distribution rights.
- Fuse/config/lock operations, multi-region memories, and package/socket
  diagrams after their CLI path and chip metadata are verified.
- Validate additional database chip families on hardware, one class at a time;
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
