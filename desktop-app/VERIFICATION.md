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
Linux CI uses Xvfb, an Openbox window manager and a private D-Bus session with
software GL and WebKit's default compositor for the headless display;
installed packages do not set these test-only variables. Package-candidate
artifacts support native-test diagnostics and are excluded from publication.
Windows QA starts the installed executable with a private WebView2 profile
and a loopback debugging port, then attaches through Tauri WebDriver. This
uses Microsoft's documented attach mode with the current runtime; normal
application launches do not enable that test port or change runtime settings.
An elevated CI caller delegates only its QA branch to a restricted token for
the same user. The child checks Medium Integrity and non-elevated status before
launching the app and drivers; token measurements and output remain in evidence.
Only successful checks for the final revision are release evidence. The
[pull request checks](https://github.com/WINVIST/xgecu-pro/pull/4/checks) show
the current revision and all three platform gates; the release itself is
published by [Verified release](https://github.com/WINVIST/xgecu-pro/actions/workflows/release.yml)
after its Windows, Linux and macOS jobs succeed for the same tag.

## Development checks recorded on 2026-10-20

- Frontend: 29 tests, strict TypeScript and production build passed.
- Desktop Rust: 47 tests passed; the large-image test is explicitly run
  separately, rather than counted as coverage when ignored by the small suite.
- Programmer workspace: 283 unit and 6 doc tests passed; five hardware/vendor
  fixture tests were explicitly ignored. Clippy and formatting passed.
- Windows USB code: GNU cross-target check and Clippy passed; native MSVC
  compilation and packaged Windows execution remain the CI gate.
- A compiled Linux development app passed all five real-backend WebDriver
  scenarios in WSL Ubuntu 25.10: missing programmer, complete catalog and
  favorite persistence after reload, native HEX edit/cancel/Undo/Redo/copy
  save, keyboard/dark/minimum-window/125% content scale, USB report export.
  This supplemental run used WSL's root test account; packaged Linux tests
  run as the hosted runner's regular user on Ubuntu 22.04.
- A compiled Linux release app also passed all five scenarios with a fresh
  cache, an unprivileged UID, Openbox and a private D-Bus/Xvfb session in WSL
  Ubuntu 25.10. WebKit sandboxing remained enabled; all WebDriver screenshots
  completed. This supplements, rather than replaces, the baseline package gates.
- The CI-built NSIS package was installed in a separate test directory on
  Windows 11 Pro x64 (build 26300). All five native WebDriver scenarios passed
  in 13.5 seconds using the installed WebView2 155.0.4283.62 and matching driver,
  a fresh cache/profile, and a measured Medium/non-elevated user token.
  Native screenshots, keyboard focus, compact layout and 125% scale passed.
- Offline cached lookup succeeded under a separate Linux network namespace;
  the empty-cache negative control failed with the expected network error.
- The explicit release-profile large-image test passed both requested sizes
  in 8.91 s, with 3,004 KiB peak RSS measured for the engine test process.

These development results complement the required package gates above.

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
