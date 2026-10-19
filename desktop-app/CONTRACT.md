# Desktop bridge contract

The approved design is the existing macOS SwiftUI app at revision 27e3ada.
English UI, T76 only, 1180x820 default / 1020x680 minimum, sidebar 290px.

All Tauri commands use camelCase arguments and serde camelCase object fields.
Failures reject with `{ code: string, message: string, hint?: string }`.

- `get_settings()` -> `{ databasePath: string, favorites: string[], theme: "system"|"light"|"dark" }`.
- `save_settings({settings})` -> same settings. Store in per-user config directory.
- `inspect_file({file})` -> `{bytes: number}` for a readable regular firmware file; bounded metadata only, no full-file read.
- `programmer_run({request})` -> existing minipro JSON result. Request:
  `{ operation: "connect"|"search"|"describe"|"autodetect"|"check"|"read"|"verify"|"blank"|"erase"|"usb_diagnose", chip?: string, query?: string, file?: string, database?: string, limit?: number, disableDeviceU1U2?: boolean }`.
- `prepare_program({chip, file, database})` -> `{token, chip, file, bytes}`. Uses a private file snapshot, locked chip/database, CLI dry-run; pending token blocks other programmer/buffer operations until consumed/cancelled.
- `commit_program({token})` -> existing minipro write result; consumes pending snapshot.
- `cancel_program({token})` -> void; discards snapshot without hardware operation.
- `buffer_command({request})` -> BufferReply below. Request fields:
  `{operation: "open"|"save"|"page"|"edit"|"fill"|"copy"|"export"|"find_hex"|"find_ascii"|"undo"|"redo"|"compare"|"state", file?: string, offset?: number, count?: number, start?: number, end?: number, destination?: number, value?: number, query?: string, originChip?: string}`.
  Range ends are inclusive (same as macOS). BufferReply:
  `{size, offset, bytes: number[], sha256, dirty, canUndo, canRedo, source?: string, originChip?: string, foundOffset?: number, firstMismatch?: number, otherBytes?: number, matches?: boolean, savedPath?: string}`.
- Event `operation-event` -> `{stage?: string, progress?: {done:number,total:number}, warn?: unknown, note?: string}`. Busy/confirmation state belongs to the caller; backend independently enforces one operation and pending snapshot exclusion.

Production must not include fixture USB adapters. A separately feature-gated E2E build may supply display/test fixtures, never a user-selectable production mock mode.
Frontend browser preview uses a separate mock adapter and clearly labels itself a preview; production never silently substitutes mocks.

The backend independently validates every request, bounds file operations, and
keeps the operation/confirmation/close state under one shared gate. Frontend
disabled controls are a usability feature, not the enforcement boundary.
