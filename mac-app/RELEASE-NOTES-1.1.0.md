XGecu Pro 1.1.0 makes the main workflow explicit: select the chip, choose a
firmware file, then program with readback verification.

- A native Program workspace, separate Hex Editor and Activity tabs,
  persistent operation status, clearer empty/loading/error states and familiar
  file shortcuts. Destructive confirmations default to Cancel.
- Complete chip browsing with live name/package filtering and persisted
  favorites. CI retrieves all 33,612 entries from the pinned T76 V13.21 catalog.
- File-backed editing and streamed raw, Intel HEX and S-record operations up
  to 2 GiB decoded. Hashing, search, comparison and edits run away from the UI
  actor. Undo/redo and overlapping-copy snapshots live in private files.
- Check Setup rechecks chip identity and reports actual contact-test
  availability. The unreliable legacy T76 pin-test command remains disabled.
- Quit protects active work and asks before discarding unsaved editor changes.

Validation includes 259 Rust tests, 14 Swift tests, an Apple Silicon Release
build, code-signature/archive checks and native light/dark/compact display
fixtures. At 1,140,850,688 bytes, conversion and editor paging/edit/undo/SHA-256/
comparison passed with about 6.6 MiB and 7.2 MiB maximum resident memory.
These are software/size checks; additional chip families and adapter wiring
require their own physical acceptance.

Requires Apple Silicon and macOS 26 or later. The app and bundled helper are
ad hoc signed; this build has no Developer ID signature or Apple notarization.
Use the ZIP and matching SHA-256 file below, following the
[installation guide](https://github.com/WINVIST/xgecu-pro/blob/v1.1.0/mac-app/README.md#install-a-prebuilt-ci-app).
Vendor databases and algorithms are not redistributed in this public archive;
the app downloads the checksum-pinned database on first use or accepts a local
extracted database for offline use.
