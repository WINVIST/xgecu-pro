# XGecu Pro for macOS

Native SwiftUI frontend for the existing Rust `minipro` CLI. The first version
targets an Apple Silicon Mac running macOS 26.7 and an XGecu T76.
All app text and project documentation are in English.
The staged implementation and hardware acceptance plan is in
[ROADMAP.md](ROADMAP.md).

## Build on the Mac

1. Copy or clone this entire repository to the Mac. The Windows checkout is
   source only; SwiftUI and `.app` must be built with Xcode on macOS.
2. Install Xcode and its command-line tools, then install Rust with
   [rustup](https://rustup.rs/) (Rust 1.85 or newer). Run
   `rustup target add aarch64-apple-darwin`.
3. Open `mac-app/XGecuPro.xcodeproj` in Xcode and run the `XGecuPro` scheme.
   The build phase compiles `minipro-cli` with the checked-in Cargo lockfile and
   places `minipro` in the app's Resources folder.

Equivalent command-line build:

```sh
xcodebuild -project mac-app/XGecuPro.xcodeproj \
  -scheme XGecuPro -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/xgecu-pro-derived CODE_SIGNING_ALLOWED=NO build
open /tmp/xgecu-pro-derived/Build/Products/Release/XGecuPro.app
```

The local build is unsigned and intended for use on your own Mac. No vendor DLL,
algorithm bitstreams, firmware, or proprietary application files are bundled.
The default database source is Xgpro T76 V13.21, verified against a pinned
SHA-256 before extraction. You can choose an existing extracted database folder
in the app to work offline.

## Use

Connect the T76 through a USB 2.0 cable or hub on Apple Silicon. Click
**Connect / Refresh**, search for a chip, select it, and use **Detect ID** or
**Read…**. **Blank Check** compares the entire code region with the
chip's erased value. **Verify Against File…** reads the chip twice and compares
the result with a selected raw, Intel HEX, or S-record image. A short image is
padded with the chip's erased value through its full code region. Reads are repeated
by the Rust backend; the app marks an
unstable result and opens the saved dump in a paged hex buffer. The buffer can
also open local files, jump to a hex address, find a byte sequence, and fill an
inclusive address range with one byte. It accepts raw files up to 64 MiB. Save
edited buffers with **Save As…** before choosing a file to program; the
**Program…** action programs the file selected in its dialog, not unsaved buffer
changes. The app shows the buffer's SHA-256 digest and compares it byte for byte
with another local file, reporting the first differing address or a size
difference. The app asks before discarding unsaved changes on a new read or open.

The GUI enables read and ID checks for AT27C256R, MX27C2000, W27C512, and
W27C257 entries. Write and erase are limited to W27C512 and W27C257, whose
repeated read/write/erase cycles were hardware-verified by upstream. Write first runs
`--dry-run`, then asks for confirmation and uses the backend's read-back
verification. The backend checks the chip ID before erase or protect changes;
the GUI also requires a T76 and a database entry with an electronic ID.
Save a dump before changing a chip. Do not disconnect the programmer during
an active operation.

NAND, eMMC, firmware update, and other experimental chip classes remain
available only through the original CLI. The app performs one operation at a
time and does not terminate an in-progress write or erase.

## Verification

On a development machine, run:

```sh
cd minipro-rs
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

On the Mac, verify the Xcode build, T76 identity and USB High Speed link, then
read a known chip twice. Only after preserving its original dump, run a
write/read/compare and erase/blank-check cycle on a disposable rewritable part.
