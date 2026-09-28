# XGecu Pro for macOS

Native SwiftUI frontend for the existing Rust `minipro` CLI. The first version
targets an Apple Silicon Mac running macOS 26.7 and an XGecu T76.
All app text and project documentation are in English.
The staged implementation and hardware acceptance plan is in
[ROADMAP.md](ROADMAP.md).
Use the [target-Mac validation checklist](HARDWARE-VALIDATION.md) when the T76
and supplied USB cable are available.
The [macOS CI workflow](../.github/workflows/macos.yml) builds the arm64 app and
runs the Rust tests on a GitHub-hosted macOS 26 runner. Hardware acceptance still
requires the target Mac and a connected T76.

## Install a prebuilt CI app

This path does not require Xcode or Rust on your Mac:

1. Sign in to GitHub and open the latest successful `macOS arm64` run for `main`
   on the [Actions page](https://github.com/WINVIST/xgecu-pro/actions/workflows/macos.yml).
2. Under **Artifacts**, download `XGecuPro-macOS-arm64-unsigned`. GitHub gives
   you an outer ZIP containing `XGecuPro-macOS-arm64.zip` and its `.sha256` file.
3. Extract the outer ZIP. In Terminal, from that folder, run
   `shasum -a 256 -c XGecuPro-macOS-arm64.zip.sha256`. After it reports `OK`,
   extract `XGecuPro-macOS-arm64.zip` and move `XGecuPro.app` to
   **Applications**. Keep the inner ZIP if you want a copy of the exact build.
4. Open the app. This CI build has an ad hoc code signature, but no Apple
   Developer ID signature or notarization. If macOS blocks it, use
   **System Settings → Privacy & Security → Open Anyway** after the first
   open attempt. Approve only the artifact from your fork's successful
   workflow run. See [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac).

If macOS instead says the app is **damaged**, first confirm the checksum in
step 3 reported `OK`, then verify the app's code signature in Terminal:

```sh
codesign --verify --deep --strict --verbose=2 /Applications/XGecuPro.app
```

On an unmanaged Mac, if verification succeeds and the app came from your
successful fork workflow, remove the download quarantine from this app only
and open it again:

```sh
xattr -dr com.apple.quarantine /Applications/XGecuPro.app
open /Applications/XGecuPro.app
```

Stop if the checksum or code signature verification fails. The quarantine
workaround is for this test build; normal distribution requires Developer ID
signing and notarization.

If **Allow applications from** says its setting is configured by a profile,
check for the separate **Open Anyway** button after an open attempt. A managed
Mac may also prohibit that exception. If it does, follow the device
administrator's policy and use an approved Developer ID signed and notarized
build; do not change the managed security setting or remove quarantine to
bypass the policy.

The archive contains the Apple Silicon app and bundled `minipro` helper. It
does not contain the vendor database or firmware. The app retrieves the pinned
database source on first use unless you select a local extracted database.
GitHub workflow artifacts expire; download a new successful run when needed.

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

The supplied USB cable is a target for hardware validation on the MacBook Pro
M3. If it negotiates SuperSpeed, the current macOS T76 backend reports a
diagnostic because bulk transfers have failed in earlier tests. A USB 2.0
cable or hub is the working High Speed fallback; the supplied cable can be
used through a USB 2.0 hub if its connectors fit. No ISP/ICSP cable is needed
for this socket-based workflow. See [ROADMAP.md](ROADMAP.md) for the direct
cable acceptance test.

Connect the T76 over a working High Speed link. Click **Connect / Refresh**.
For either requested Macronix chip in a verified SOIC16 adapter, click
**Auto Detect SOIC16**. For either requested JEDEC ID, the app selects the
matching database entry and checks its package, capacity, and ID before
enabling reading. Confirm the chip marking and adapter placement before Read.
Alternatively, search for the
chip name and select its exact `@SOIC16` entry. Then use **Read…**. The separate
**Detect ID** action rechecks the selected chip's ID. **Blank Check** compares
the entire code region with the
chip's erased value. Selecting a chip also shows its database package, pin
count, memory region sizes, page size, expected electronic ID, and erased value
without connecting the programmer. The package label is not a socket placement
guide; check the programmer's verified placement instructions before seating a
part. Search covers the vendor database, including parts for which this build
does not enable hardware operations. **Verify Against File…** reads the chip
twice and compares
the result with a selected raw, Intel HEX, or S-record image. A short image is
padded with the chip's erased value through its full code region. Reads are repeated
by the Rust backend; the app marks an
unstable result and opens the saved dump in a paged hex buffer. The buffer can
also open local raw, Intel HEX, and Motorola S-record files, jump to a hex
address, find a byte sequence, and fill an inclusive address range with one
byte. Address gaps in HEX and S-record files are filled with `0xFF`. The image
limit is 64 MiB; text image inputs are limited to 256 MiB on disk. **Save As…**
chooses raw, Intel HEX, or S-record output from the file extension. Save
edited buffers with **Save As…** before choosing a file to program; the
**Program…** action programs the file selected in its dialog, not unsaved buffer
changes. The app shows the buffer's SHA-256 digest and compares it byte for byte
with another local file, reporting the first differing address or a size
difference. You can edit an individual byte or fill a range, then undo and redo
edits. Search accepts printable ASCII text as well as HEX bytes. Block addresses
are inclusive: **Copy** duplicates a source block at a destination address in
the buffer, even when the ranges overlap; **Export…** writes the selected block
to a separate raw file. The app asks before discarding unsaved changes on a new
read or open.

The GUI enables read and ID checks for AT27C256R, MX27C2000, W27C512, and
W27C257 entries. Write and erase are limited to W27C512 and W27C257, whose
repeated read/write/erase cycles were hardware-verified by upstream. Write first runs
`--dry-run`, then asks for confirmation and uses the backend's read-back
verification. The backend checks the chip ID before erase or protect changes;
the GUI also requires a T76 and a database entry with an electronic ID.
Save a dump before changing a chip. Do not disconnect the programmer during
an active operation.

`MX25L51245GMI-10G` and `MX25L25645GMI-08G` are requested targets. The
user confirmed these exact markings. They are 3 V, 16-SOP serial NOR parts.
The pinned T76 V13.21 database lists them as `MX25L51245G@SOIC16` (64 MiB,
ID `C2201A`) and `MX25L25645G@SOIC16` (32 MiB, ID `C22019`). The GUI enables
ID detection, read, blank check, and file comparison only when these exact
database details match. Their socket placement, algorithm behavior, and full
read results still require live validation. Write and erase remain disabled.
See the [hardware acceptance plan](ROADMAP.md#user-requested-hardware-support).

NAND, eMMC, firmware update, and other experimental chip classes remain
available only through the original CLI. The app performs one operation at a
time and does not terminate an in-progress write or erase.

## Verification

On a development machine, run:

```sh
cd minipro-rs
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cd ../mac-app
swift test
```

On the Mac, verify the Xcode build, T76 identity and USB High Speed link, then
read a known chip twice. Only after preserving its original dump, run a
write/read/compare and erase/blank-check cycle on a disposable rewritable part.
