# T76 hardware validation on the target Mac

Use this checklist on the MacBook Pro M3 running macOS 26.7. It records the
evidence still needed to accept the first usable build. Install or build the
app using the [README](README.md) first. Keep the original chip dumps and the
completed record in a private location.

## 1. Check the supplied USB cable

1. Connect the T76 directly with the supplied USB cable. With no chip in the
   socket, open **System Information → USB** and record the T76's negotiated
   speed. Optionally save the listing with
   `system_profiler SPUSBDataType > usb-direct.txt`.
2. In XGecu Pro, click **Connect / Refresh**. Record the displayed model,
   firmware, USB link, and any error text. A SuperSpeed diagnostic means chip
   operations must wait for a working link.
3. If direct SuperSpeed does not work, connect the supplied cable through a
   USB 2.0 hub, if its connectors fit. Repeat the speed and Connect / Refresh
   checks. Record which connection succeeds. Do not infer direct-cable support
   from a successful hub test.

## 2. Read the two photographed Macronix parts

Only proceed on a working T76 connection. Use the correct 300 mil SOP16 adapter
and the manufacturer's verified pin-1 and placement instructions. The package
name in the app is not a placement diagram. Keep the original chips untouched
until placement and voltage are confirmed.

For each part, use **Auto Detect SOIC16** and record the reported JEDEC ID and
selected `@SOIC16` database entry. Confirm the marking and adapter placement,
run **Detect ID**, then use **Read…** twice and save two separate raw `.bin` files.
If autodetect fails, record the full error before trying the manual search.
If **Detect ID** or **Read…** reports overcurrent, stop chip operations and
save the Log text. Do not rotate the chip in the adapter to work around that
message. The T76 transaction setup may differ from the autodetect probe; a
successful JEDEC probe alone does not prove that the read setup is safe.
Each Read action also performs an internal second read; the two saved files
provide an external comparison.

| Chip marking | Database entry | Expected ID | Expected raw dump size |
| --- | --- | --- | ---: |
| `MX66L1G45GMI-08G` | `MX66L1G45G@SOIC16` | `C2201B` | 134,217,728 bytes |
| `MX25L51245GMI-08G` | `MX25L51245G@SOIC16` | `C2201A` | 67,108,864 bytes |

The MX66L1G45G database entry also lists 512 data bytes. The current Read
action saves the 128 MiB code region; record the 512-byte auxiliary region
separately when multi-region support is implemented.

### Observed results

On the target Mac, the user reported that the T76 connected directly through
the supplied USB cable as firmware `00.1.18` over USB High Speed. This
establishes a working direct connection, although the System Information USB
listing has not been retained. **Auto Detect SOIC16** offered
`MX66L1G45G@SOIC16`; **Detect ID** returned `C2201B` and also listed the
`MX66L1G85G` variants that share this ID. The printed marking identifies the
selected `MX66L1G45G@SOIC16` entry. A **Program…** action ended with
“Programming completed and verified by a readback.” Its Log also showed
`firmware_mismatch` warnings against the pinned database target.

After Program, two separate **Read…** actions saved `MX66-read-1.bin` and
`MX66-read-2.bin`. The user reported that each file is 134,217,728 bytes,
both have SHA-256
`2efabaa8f50229fa23be3c6472ea169175f592a21d4e56a5c184080dd0c31dec`,
and external `cmp -s` exited with status `0`. The app reported “Dump saved
and confirmed by a second read” and “Chip contents match the file” for a
subsequent Verify Against File operation. This validates a stable full code
region read of the *current, programmed contents*. The app does not include
the separate 512-byte data region in these dumps.

The original pre-program image and any original pre-program dump have not yet
been established in this record; the user was unsure whether a dump was saved
before Program. The Hex buffer shown immediately after Program was not
automatically refreshed from the chip; only the subsequent Read results above
are evidence of a post-program dump.

For the photographed `MX25L51245GMI-08G`, the user reported **Detect ID**
`C2201A`, selected `MX25L51245G@SOIC16`, and saved `MX25-read-1.bin` and
`MX25-read-2.bin`. Both files are 67,108,864 bytes, both have SHA-256
`c9a54490897ea9dfc24eaf136dd7663a87b56c890e98715ee05c531dc5807ef9`,
and external `cmp -s` exited with status `0`. The app reported “Chip contents
match the file” after Verify Against File. This validates a stable full code
region read of the current MX25 contents. MX25 programming and erase have not
been tested on this Mac.

The MX25 screenshot's Hex panel still shows the 134,217,728-byte MX66 buffer
and its `2efabaa8…` SHA-256. Selecting or detecting another chip does not
replace the buffer. The app now labels the source file and source chip and
warns when the selected chip differs. Use **Read…** or **Open File…** to inspect
the MX25 dump in Hex; the shell size, hash, and comparison output above are
the evidence for the two MX25 files.

For each pair, check sizes and hashes in Terminal, replacing the filenames:

```sh
stat -f '%N: %z bytes' first.bin second.bin
shasum -a 256 first.bin second.bin
cmp first.bin second.bin
```

`cmp` exits with status 0 and prints nothing when the files match. Keep both
files even when they differ, and record the app's stability message. Then use
**Verify Against File…** with one saved dump and record the result. Do not
enable write or erase for these Macronix parts based on ID detection alone.

## 3. Record the result

```text
Mac model / macOS version:
Xcode / Rust versions:
T76 firmware / database version:
Direct supplied-cable speed and Connect / Refresh result:
USB 2.0 hub speed and result, if used:
Adapter model and confirmed placement source:
Chip marking / database entry:
Detect ID result:
Read 1 and Read 2 stability messages:
Dump sizes and SHA-256 hashes:
External cmp result / Verify Against File result:
Errors or unexpected behavior:
```

The [roadmap](ROADMAP.md) lists separate destructive acceptance tests on
disposable parts. The GUI now exposes database-driven program and erase
controls where an electronic ID and erase capability are present. Do not use
them on the requested Macronix parts until their placement, repeated full
reads, and original backup have been checked. Test mutation first on a
disposable rewritable part. The observed MX66L1G45G programming and both
chips' repeated read passes do not establish an original MX66 backup or
validate MX25 write/erase.
