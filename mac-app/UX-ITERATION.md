# Programming workflow usability — 2026-10-15

The user's main task is to insert a chip, choose a firmware binary, and flash
it. This iteration prioritizes that task before expanding the catalog or
adding backend operations. App text remains English.

## Source review and resulting changes

The previous view placed six chip actions in one row, showed detailed chip
metadata above every operation, and displayed all hex editing tools at once.
These are findings from the view source, not a captured user-flow audit.

- The default Program tab gives chip selection, firmware selection, and
  programming separate numbered sections. It shows the chosen source file
  before starting preflight and explains disabled programming prerequisites.
- Chip package/capacity remain visible; less-used database fields expand on
  request. Native sidebar selection supports keyboard navigation. Empty
  search results explain the next step.
- Read, verify, blank check, and erase remain in a secondary disclosure.
  Hex Editor and Activity are separate workspaces. Status and real backend
  stage progress remain visible beneath all tabs.
- Hex navigation has named accessible controls. Search uses one HEX/ASCII
  format selector; source/checksum and buffer-edit tools expand on request.
- Familiar file/refresh shortcuts are available from the macOS menu bar.
  Programming and erase have no default Return shortcut. Their final alerts
  default to Cancel and retain an explicit commit action.

Programming still runs the existing private image snapshot, `write --dry-run`,
electronic-ID preflight, confirmation, and write/readback verification. Choosing
a firmware file does not replace the hex buffer. The firmware file is captured
again into a private snapshot at preflight time; the displayed size is the size
observed at selection and is not the decoded capacity of a HEX/S-record image.

## Design sources

Use native SwiftUI components, semantic system colors, SF Symbols, explicit
action labels, and progressive disclosure. The sources consulted were Apple's
[buttons](https://developer.apple.com/design/human-interface-guidelines/buttons),
[toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators),
and [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
guidelines. The destructive commit is never the default Return action.

## Verification and target-Mac review

GitHub macOS CI builds the Release application, runs the existing Rust and
Swift suites, and compiles a separate native UI capture executable. Its
display fixtures cover initial, ready, progress, error, compact dark, and hex
states. The capture executable is not bundled in the application and does
not issue programmer commands. PNGs are published as
`XGecuPro-native-ui-previews`; the installable application and checksum are
available for PRs as well as main. Test fixtures are not a live chip test.

On the target Mac, review:

1. Connect, use SOIC16 auto detection or keyboard chip search/selection, and
   confirm the exact package/marking.
2. Choose a firmware file and confirm the displayed filename/path. Cancel
   the file chooser and verify the existing selection remains.
3. Start preflight on an appropriate test part; cancel the confirmation and
   check that no write begins. Return must choose Cancel.
4. Check the complete write/verify result on a disposable supported chip.
5. Open/edit/save a buffer; confirm unsaved edits are not silently programmed.
6. Check compact/resized windows, light/dark appearance, keyboard-only use,
   VoiceOver labels, long part names and file paths, and errors.

The user authorized continuing the primary roadmap. Catalog/favorites and
file-backed streaming are now implemented; UI fixtures also cover catalog
filtering and favorites. Check Setup rechecks chip identity without mutation
and reports unavailable contact diagnostics explicitly. The T76 backend does
not expose its untrustworthy legacy contact-test opcode.

Large file operations run outside the UI actor with a visible busy stage.
The editor preserves the source file, bounded page reads, overlapping-copy
snapshots, disk-backed undo/redo, and byte-for-byte file comparison. CI
measures the converter and editor separately on a 1,140,850,688-byte image;
both must remain below 128 MiB maximum resident memory.

Quit waits until an active operation finishes and asks before discarding
unsaved edits. The discard alert defaults to Cancel. On the target Mac, check
Command-Q during a read/write and while the Hex Editor has unsaved edits.
