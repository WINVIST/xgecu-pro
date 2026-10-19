# Verification record — 1.2.0-beta.1

## Required software gates

The `Desktop x64` workflow builds on Windows Server 2025 and Ubuntu 22.04.
The Windows user target is Windows 11 x64; a hosted Windows runner is not a
physical Windows 11 workstation test. Linux package baseline is Ubuntu 22.04
and Debian 12; the DEB dependencies are explicit, and the AppImage is built on
the oldest supported baseline.

| Gate | Evidence |
|---|---|
| UI build/types and behavior | `npm run build`, Vitest hook/adapter/policy/modal tests |
| Rust programmer regression | Existing workspace tests, clippy, format check on all three OS builds |
| Desktop bridge | Typed argument restrictions, drained NDJSON pipes, helper exits/errors, one-use confirmation, locked image/database snapshots, close/dirty-state tests |
| HEX engine | Source preservation, atomic replacement, BIN/HEX/Srec, Unicode paths, boundaries, search, overlapping copy, disk undo/redo and failed I/O protection |
| Large images | Explicit 1,140,850,688-byte and 2,147,483,648-byte exercise; Linux test-process RSS below 128 MiB |
| Database | Fresh-cache pinned archive extraction, complete catalog and Unicode conversion; cached lookup succeeds and an empty-cache control fails under a private Linux network namespace or a Windows outbound rule scoped to the helper |
| Packaged native apps | Installation, WebDriver interaction and screenshots for Windows and Linux; no-device USB report export |
| macOS regression | Existing SwiftUI fixtures, Swift and Rust tests, large-image checks, DMG/ZIP verification |
| Published downloads | Version/tag alignment, exact expected asset set and independent SHA-256 verification |

Evidence artifacts are `XGecuPro-Windows-verification`,
`XGecuPro-Linux-verification`, and the existing macOS UI/package artifacts.
Only successful checks for the final revision are release evidence. Detailed
completed-run links and final counts are recorded here before handoff.

## Visual reference

The reference is macOS revision `27e3ada`, captured by its existing UI fixture
job. Compare Program, compact dark and HEX layouts: sidebar width, centered
tabs, three numbered programming groups, persistent status, compact typography,
gray surfaces and disclosure hierarchy. Inter, Lucide icons, platform file
paths, precise MiB units and native title bars/dialogs are intentional platform
differences. Browser-only previews display an explicit fixture banner that is
absent from installed applications.

## Physical T76 acceptance — pending

No connected T76 was used in the Windows/Linux development or CI checks.
Read/write/erase compatibility on either new platform remains unconfirmed.
Existing macOS results in [HARDWARE-VALIDATION.md](../mac-app/HARDWARE-VALIDATION.md)
apply only to the documented chips, setup and operating system.

Before promoting the preview to a stable cross-platform release, record for
each OS: application revision, programmer firmware, USB speed, driver/rule,
cable/hub/adapter and exact chip. On a disposable supported test chip, check:

1. Connect, reconnect and baseline diagnostics; close other programmer apps.
2. Repeated stable reads and independent SHA-256 comparison of their dumps.
3. Correct package selection, chip-ID mismatch rejection and canceled preflight.
4. Program known test data, full readback verification and a separate repeated read.
5. Erase/blank-check only on a suitable electrically erasable part.
6. Errors after unplug/replug, unsaved-close protection and restored driver access.

Chip readback equality proves data consistency, not BIOS POST or BMC startup.
No firmware update, new programmer family, SOIC8 autodetection or BIOS/BMC
region-preservation implementation is implied by this port.
