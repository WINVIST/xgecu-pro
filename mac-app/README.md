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

Once a GitHub Release is published, download its app ZIP and matching
`.sha256` file from the [Releases page](https://github.com/WINVIST/xgecu-pro/releases)
and start at step 3 below. Until then, use a successful CI artifact.

1. Sign in to GitHub and open the latest successful `macOS arm64` run for `main`
   on the [Actions page](https://github.com/WINVIST/xgecu-pro/actions/workflows/macos.yml).
2. Under **Artifacts**, download `XGecuPro-macOS-arm64-unsigned`. GitHub gives
   you an outer ZIP containing `XGecuPro-macOS-arm64.zip` and its `.sha256` file.
3. For an Actions artifact, extract the outer ZIP; Release assets are already
   separate files. In Terminal, from the folder containing the app ZIP and its
   `.sha256` file, run `shasum -a 256 -c XGecuPro-macOS-arm64.zip.sha256`.
   After it reports `OK`, extract `XGecuPro-macOS-arm64.zip` and move
   `XGecuPro.app` to **Applications**. Keep the ZIP if you want a copy of the
   exact build.
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

The often quoted `xattr -cr /Applications/XGecuPro.app` removes **all** extended
attributes recursively. The command above removes only the download
quarantine attribute and is the narrower choice after checksum and signature
verification. Neither command adds Apple notarization.

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
After that download, later operations use the extracted local cache without
network access. The application does not redistribute the proprietary vendor
database or FPGA algorithms.
GitHub workflow artifacts expire; download a new successful run when needed.

### Make a personal offline copy

After the first successful database download, you can package your own cached
copy into a separate `.app` on the Mac. Download and unpack the CI artifact,
then run this script from the cloned repository (replace the app paths):

```sh
bash mac-app/scripts/make-personal-offline-app.sh \
  /path/to/XGecuPro.app /path/to/XGecuPro-Offline.app
```

The script uses `~/Library/Caches/minipro/xgpro-pinned-v1321` by default. Pass
the extracted database directory as a third argument if yours is elsewhere.
It checks the database with the bundled helper, copies the catalog and FPGA
algorithms, signs the personal app ad hoc, and verifies its signature. The app
then shows **Database: bundled for offline use** and needs no database network
request. Keep that personal copy private; public CI archives and GitHub
Releases do not include XGecu's proprietary files. A manually chosen local
database in the GUI still takes precedence over the bundled copy.
Use **Use Bundled / Automatic Database** to return to the packaged or cached
default after choosing a different local database.

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

The supplied USB cable worked directly on the target MacBook Pro M3 at USB
High Speed for T76 detection and repeated full MX66L1G45G reads. If another
connection negotiates SuperSpeed, the current macOS T76 backend reports a
diagnostic because bulk transfers have failed in earlier tests. A USB 2.0
cable or hub remains a High Speed fallback. No ISP/ICSP cable is needed for
this socket-based workflow. See [HARDWARE-VALIDATION.md](HARDWARE-VALIDATION.md)
for the recorded result and remaining checks.

Connect the T76 over a working High Speed link. Click **Connect / Refresh**.
For a serial flash in a verified SOIC16 adapter, click **Auto Detect SOIC16**.
The programmer reads its JEDEC ID and the app lists all SOIC16 entries with
that ID in the selected database. If there is one entry, it is selected;
otherwise choose the entry matching the printed chip marking. A shared JEDEC
ID is not proof of an exact model. Confirm the marking and adapter placement
before any operation.
Alternatively, search for the
chip name and select its exact `@SOIC16` entry. Then use **Read…**. The separate
**Detect ID** action rechecks the selected chip's ID. **Blank Check** compares
the entire code region with the
chip's erased value. Selecting a chip also shows its database package, pin
count, memory region sizes, page size, expected electronic ID, and erased value
without connecting the programmer. The package label is not a socket placement
guide; check the programmer's verified placement instructions before seating a
part. Search covers the vendor database. **Verify Against File…** reads the chip
twice and compares
the result with a selected raw, Intel HEX, or S-record image. A short image is
padded with the chip's erased value through its full code region. Reads are repeated
by the Rust backend; the app marks an
unstable result and opens the saved dump in a paged hex buffer. The buffer can
also open local raw, Intel HEX, and Motorola S-record files, jump to a hex
address, find a byte sequence, and fill an inclusive address range with one
byte. Address gaps in HEX and S-record files are filled with `0xFF`. The image
buffer, verification, and programming limit is 256 MiB; text image inputs are
limited to 256 MiB on disk. Larger code regions up to 2 GiB can be read to a
raw file with a second-pass stability check. Their dumps are not opened in
the hex buffer. **Save As…**
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

The GUI uses the entire selected database, without a hardcoded chip allowlist.
Read, ID check, and blank check are offered for entries with a nonempty
code region up to the 2 GiB streamed read limit. Verify is offered up to
256 MiB. Program is offered up to 256 MiB when
the entry also has an electronic ID; Erase additionally requires the database
to mark the part electrically erasable. The backend can still refuse an
unsupported chip family or algorithm. These controls are **not** a claim that
every database part has been tested on hardware. Write first runs `--dry-run`,
then asks for confirmation and uses the backend's read-back verification.
The operation area displays the current stage beside its spinner or progress
bar. The **Log** tab records timed stage changes, progress at 10% milestones,
warnings, and the final result. A successful Program does not replace the Hex
buffer with a fresh chip read; use **Read…** to save and inspect a new dump.
Short programming images are padded to chip capacity with the part's erased
byte, as stated in the confirmation dialog.
The backend checks the chip ID before erase or protect changes; the GUI also
requires a connected T76 and an ID for mutations.
Save a dump before changing a chip. Do not disconnect the programmer during
an active operation.

`MX66L1G45GMI-08G` and `MX25L51245GMI-08G` are the current target chips,
confirmed by photographs. They are 3 V, 16-SOP serial NOR parts. The pinned
T76 V13.21 database lists them as `MX66L1G45G@SOIC16` (128 MiB,
ID `C2201B`) and `MX25L51245G@SOIC16` (64 MiB, ID `C2201A`). The GUI enables
ID detection, read, blank check, file comparison, program, and erase through
the same database-driven controls as other parts. Their socket placement,
algorithm behavior across the wider catalog still requires live validation.
For `MX66L1G45G@SOIC16`, one user-reported T76/macOS programming attempt
completed with backend read-back verification. Two subsequent full 128 MiB
raw reads matched by SHA-256 and external `cmp`, and Verify Against File
reported a match. These results cover the current programmed code region;
the pre-program original image/dump remains unconfirmed. For
`MX25L51245G@SOIC16`, two full 64 MiB reads matched by SHA-256 and external
`cmp`, and Verify Against File reported a match. MX25 programming and erase
have not yet been validated on the target Mac. The Hex panel labels the buffer
source and warns if it was read from a chip other than the selected one;
selecting another chip does not replace the buffer.
Preserve two matching original dumps before attempting any destructive operation.
For MX66L1G45G, **Read…** saves the 128 MiB code region; its separate 512-byte
data region is outside the current GUI read workflow.
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
