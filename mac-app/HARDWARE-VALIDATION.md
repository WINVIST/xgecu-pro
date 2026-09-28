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

## 2. Read the two requested Macronix parts

Only proceed on a working T76 connection. Use the correct 300 mil SOP16 adapter
and the manufacturer's verified pin-1 and placement instructions. The package
name in the app is not a placement diagram. Keep the original chips untouched
until placement and voltage are confirmed.

For each part, use **Auto Detect SOIC16** and record the reported JEDEC ID and
suggested entry. Select the corresponding `@SOIC16` database entry, run
**Detect ID**, then use **Read…** twice and save two separate raw `.bin` files.
If autodetect fails, record the full error before trying the manual search.
Each Read action
also performs an internal second read; the two saved files provide an external
comparison.

| Chip marking | Database entry | Expected ID | Expected raw dump size |
| --- | --- | --- | ---: |
| `MX25L51245GMI-10G` | `MX25L51245G@SOIC16` | `C2201A` | 67,108,864 bytes |
| `MX25L25645GMI-08G` | `MX25L25645G@SOIC16` | `C22019` | 33,554,432 bytes |

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
disposable Winbond parts. The requested Macronix parts remain read-only until
their algorithm, placement, full reads, and later disposable-part tests justify
expanding support.
