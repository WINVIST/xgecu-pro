XGecu Pro 1.1.2 improves T76 USB connections on macOS and adds general-purpose
USB diagnostics for any cable, hub, adapter or dock.

- Recover a missing macOS USB interface when the T76 rejects GET_CONFIGURATION,
  using one bounded configuration selection. Working connections are preserved.
- Enable chip programming and erase over USB 3 with the existing chip-ID checks,
  confirmations and mandatory programming readback. Programmer firmware updates
  on macOS T76 still require USB 2.
- Replace hub-brand presets with generic connection types and optional notes.
  Show measured USB speed, firmware, detection/interface/exchange results and
  useful next steps. Keep technical details and the USB sleep experiment under
  expandable sections. Reports can be copied or saved locally, including failures.
- Retain the drag-to-Applications DMG, ZIP alternative, SHA-256 files and
  copyable first-launch instructions.

Hardware reports on MacBook Pro 16-inch M3 Pro / macOS 26.7.1 / T76 firmware
00.1.18 include a full 64 MiB MX25L51245G comparison through Wavlink and a
successful Program and Verify result through UGREEN. These are specific tested
setups, not a guarantee for every hub or chip. See the
[hardware record](https://github.com/WINVIST/xgecu-pro/blob/v1.1.2/mac-app/HARDWARE-VALIDATION.md).

Requires Apple Silicon and macOS 26 or later. The app and helper are ad hoc
signed, without Developer ID or Apple notarization. Verify the downloaded
checksum and follow the
[installation guide](https://github.com/WINVIST/xgecu-pro/blob/v1.1.2/mac-app/README.md#install-a-prebuilt-ci-app)
and the included first-launch instructions.

Vendor databases, programmer firmware and proprietary algorithms are not
bundled in public downloads.
