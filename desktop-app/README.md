# XGecu Pro for Windows and Linux

The Windows and Linux applications reproduce the macOS programmer workflow:
select the exact chip, choose firmware, then **Program and Verify**. A searchable
catalog and favorites, file-backed HEX editor, Activity log and USB diagnostics
share one window. macOS continues to use its existing SwiftUI application.

**1.2.0-beta.1 is a preview.** Windows/Linux chip operations have not yet been
validated with a physical T76. CI checks software, real packaged applications,
database setup and missing-device behavior; it does not establish hardware
compatibility. The desktop GUI supports T76 only. Other programmer families in
the CLI retain their existing, separately documented validation status.

## Downloads

Download from the [1.2.0-beta.1 release](https://github.com/WINVIST/xgecu-pro/releases/tag/v1.2.0-beta.1):

| Platform | Package |
|---|---|
| Windows 11 x64 | `XGecuPro-Windows-x64-setup.exe` |
| Ubuntu 22.04+ / Debian 12+ x64 | `XGecuPro-Linux-x64.deb` |
| Compatible x64 Linux distributions | `XGecuPro-Linux-x64.AppImage` |

Each package has an accompanying `.sha256` file. The AppImage is built on
Ubuntu 22.04 to avoid raising the glibc requirement accidentally. It is not a
promise that every distribution, graphics stack or desktop environment works.
ARM64 and 32-bit systems are outside this release.

## Windows installation and USB

1. Verify the download: `Get-FileHash .\XGecuPro-Windows-x64-setup.exe -Algorithm SHA256`
   and compare with its `.sha256` file.
2. Run the installer. It installs for the current user. WebView2 is normally
   present on Windows 11; its embedded bootstrapper needs Internet access if
   the runtime is missing. This preview has no Authenticode signature; verify
   its origin and hash before running it.
3. Connect the T76, close other programmer applications and click **Connect / Refresh**.

The T76 interface must use Microsoft's **WinUSB** driver. On Windows, startup
runs a read-only connection/driver check; Connect / Refresh repeats it after
reconnecting. **USB Diagnostics → USB setup and recovery** contains the manual
installation and restoration steps. The app never installs or changes a
driver. If the existing binding is
incompatible, record its name and provider in Device Manager before changing it.
Use [Zadig](https://zadig.akeo.ie/) from its official site, show all devices and
select only the T76 with USB ID **A466:1A86**, then choose WinUSB. Do not select a
hub, keyboard or unrelated device.

Changing this binding can affect the vendor Xgpro application. To restore the
previous binding, use Device Manager's **Roll Back Driver** when available, or
reinstall the original vendor driver and reconnect the T76. Driver installation
may require administrator rights; ordinary application use does not.

## Linux installation and USB

For the DEB, verify its checksum and install with dependencies:

```sh
sha256sum -c XGecuPro-Linux-x64.deb.sha256
sudo apt install ./XGecuPro-Linux-x64.deb
sudo udevadm control --reload-rules
```

Unplug/reconnect the programmer after reloading. The package installs a udev
rule scoped to **a466:1a86**, granting the active local desktop user access.
It does not make all USB devices world-writable. Run the GUI as your regular
user, rather than root.

For AppImage:

```sh
sha256sum -c XGecuPro-Linux-x64.AppImage.sha256
chmod +x XGecuPro-Linux-x64.AppImage
./XGecuPro-Linux-x64.AppImage
```

To obtain and install its included udev rule without running the GUI:

```sh
./XGecuPro-Linux-x64.AppImage --appimage-extract
sudo install -m 0644 squashfs-root/usr/lib/udev/rules.d/70-xgecu-pro.rules /etc/udev/rules.d/70-xgecu-pro.rules
sudo udevadm control --reload-rules
```

Reconnect the T76. If the machine lacks FUSE support, the AppImage runtime also
supports `APPIMAGE_EXTRACT_AND_RUN=1 ./XGecuPro-Linux-x64.AppImage`. The DEB is the
preferred option on the supported Debian/Ubuntu baseline. AppImage includes
its own `bsdtar` and extractor libraries; it does not require a host RAR tool.

## Database and offline use

The public packages contain no XGecu database, firmware or proprietary FPGA
bitstreams. The first catalog lookup downloads the pinned vendor archive,
verifies its SHA-256 and extracts the required database into the user's cache.
Windows includes a static libarchive `bsdtar` with a UTF-8 process manifest:
system `tar.exe` cannot read an unselected Chinese PDF name in this particular
vendor installer on every system locale. The CLI also supports system
`tar.exe`, opening Unicode archive paths through a file handle. DEB declares
`libarchive-tools`; AppImage supplies a separate extractor. Vendor installer
EXE files are read as archives and are never executed.

Later lookups reuse the cache without a network connection. **Chip database
settings → Choose Local Database…** accepts an owner's already-extracted
database directory. The bridge also accepts supported archive input through
its typed API; it never silently falls back from a failed explicit selection
to a different database. **Use Automatic Database** restores the pinned source.

Settings live in the operating system's per-user configuration directory for
`ru.winvist.xgecupro`; database cache paths follow the existing `minipro` helper.
No settings are synchronized between computers or operating systems.

## Program and inspect

- Select the exact marking and package. SOIC16 auto detection suggests entries;
  it does not establish seating, voltage or validated compatibility by itself.
- Choose a firmware file. Its source is separate from the editor buffer.
- Program captures private firmware and database copies, checks capabilities
  and chip ID with a dry run, then asks for confirmation. Cancel is the default.
  The confirmed operation uses the same snapshots and performs readback verify.
- Electrically erasable chips are erased before programming. Short images use
  the existing erased-byte padding policy, explained in the confirmation.
  This release does not implement partial BIOS/BMC-region preservation.
- Read saves a dump and checks it with a second read. Verify, Blank Check and
  Erase are under **Read, compare or erase the chip**. Erase requires an explicit
  confirmation. Save a known-good original before changing a chip.

The editor supports BIN, Intel HEX and S-record images up to **2 GiB**. Known
binary suffixes `.bin`, `.rom` and `.raw` always preserve literal bytes. Files
are copied to private working storage, paged in bounded chunks, and never
edited in place. Save As/export atomically replace the selected destination;
they refuse overwriting the opened original. Disk-backed Undo/Redo retains a
bounded history. Search, SHA-256 and comparison stream through the file.

One operation runs at a time. Conflicting controls and application close are
blocked while it is active or a programming confirmation is pending. Closing
with unsaved editor changes asks before discarding. Ctrl+O chooses firmware,
Ctrl+Shift+O opens an editor file, Ctrl+Shift+S saves a copy and Ctrl+R refreshes
the programmer. Workspace tabs support arrow keys, Home and End.

USB Diagnostics checks information replies across idle pauses without chip
read/write/erase commands. Start with the baseline test. The optional U1/U2
experiment is for a confirmed USB 3 connection and restores its temporary
changes; reconnect after the experiment. Reports remain local until copied or
saved and include optional connection notes. A passing USB test does not prove
successful chip programming.

## Build and verify

Use Node.js 24, npm and a current Rust stable toolchain. Windows additionally
needs the MSVC C++ build tools and WebView2. Linux build dependencies follow
[Tauri prerequisites](https://v2.tauri.app/start/prerequisites/); install
`libarchive-tools`, `patchelf`, `xvfb`, `webkit2gtk-driver` and `time` for packaging/tests.

From `desktop-app`:

```sh
npm ci
cargo build --release --locked --manifest-path ../minipro-rs/Cargo.toml
npm run stage-helper
npm run build
npm test
cargo test --manifest-path src-tauri/Cargo.toml --lib --locked
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets --locked -- -D warnings
npm run tauri -- dev
```

For Windows packaging, first run `./scripts/prepare-windows-extractor.ps1`
in PowerShell (CMake and MSVC are required), then
`npm run tauri -- build --config src-tauri/tauri.windows.conf.json`.
The extractor source and SHA-256 are pinned; its license and provenance ship
with the app. The script does not modify the system `tar.exe` or Windows locale.
For Linux, run `bash scripts/prepare-extractor.sh` before
`npm run tauri -- build --config src-tauri/tauri.linux.conf.json`.

`npm run dev` alone is a clearly labeled browser display preview. Its separate
fixture adapter is removed from production builds; the installed application
never substitutes pretend USB data when a real operation fails.

Native WebDriver tests (`npm run test:e2e`, with `tauri-driver` installed) run
against the installed app. They supply only native file-picker results and
exercise actual buffer I/O, helper execution, settings, keyboard interaction,
themes and no-device diagnostics. They do not replace the USB transport.
On a headless Linux host, use `bash scripts/run-linux-native.sh` as a regular
user with Xvfb, Openbox, wmctrl, dbus-x11 and procps installed. It creates a
private display/session bus and preserves native display and WebDriver logs.
On Windows, `./scripts/run-windows-native.ps1` launches `XGECU_E2E_APP` with
a private WebView2 test profile and attaches Tauri WebDriver to its loopback
port. It uses the installed runtime and leaves the normal app configuration
unchanged. Run this QA script in PowerShell 7.4 or later, with matching Edge
WebDriver and `tauri-driver` on PATH.
`node scripts/check-large-buffer.mjs` explicitly runs the 1.14 GiB and 2 GiB
test and checks Linux engine peak RSS below 128 MiB, excluding compilation.

See [verification and hardware acceptance](VERIFICATION.md) and the
[desktop bridge contract](CONTRACT.md). The release workflow publishes only
after Windows, Linux and existing macOS checks all succeed for the tag.
