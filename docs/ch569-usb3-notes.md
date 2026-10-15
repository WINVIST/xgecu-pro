# T76 SuperSpeed on macOS: evidence and experiments

Updated 2026-10-15. Earlier notes described U1/U2 link power management as a
confirmed cause. That exceeded the evidence: the exact cause remains unproven.
A controller error, BOS descriptors and WCH reference code do not establish
which handshake the actual T76 firmware misses.

## Observations

The 2026-08-12 C/libusb investigation recorded working EP0 descriptors and
interface claims, followed by `kIOReturnNotResponding` (`0xe00002ed`) on the
first bulk OUT to endpoint 0x01 at SuperSpeed. The command endpoints advertised
1024-byte packets, no streams. High Speed worked. See [the original record](minipro-setup.md).

Stable 1.1.1 / diagnostic build 5 rejected macOS + T76 + SuperSpeed in
`check_link()` **before sending system-info**. That was a compatibility guard,
not a fresh transfer failure. Ordinary opens also cycled configuration 0→1;
diagnostics skipped it. Build 6 removes the cycle and allows normal connection,
chip identification, reads and comparisons at SuperSpeed. Programming, erase
and programmer firmware updates remain blocked on macOS T76 SuperSpeed pending
full chip-transfer validation. USB2 and other platforms/models retain their policy.

User reports on 2026-10-15: MacBook Pro 16-inch M3 Pro; report confirms macOS
26.7.1 (25G241), T76 firmware 00.1.18. These are connection observations, not chip read/write
validation:

| Connection | Reported result | Link evidence |
|---|---|---|
| Mac → Digma DHUB-LAN-4port → T76 | works | app displays `hs` |
| Mac → Wavlink WL-UG69PD25 Pro → Digma → T76 | works | measure separately |
| Mac → UGREEN CM512 / P/N 45000 → T76 | compatibility error | guarded CLI does not attempt bulk transfer |
| Mac → Wavlink WL-UG69PD25 Pro → T76 | build 5 baseline passes all 4 probes | OS reports Super; EP01/81 MPS 1024; firmware 00.1.18 |

The baseline report at 2026-10-15T11:47:52Z measured 98 ms for every system-info
exchange after 0/100/1000/3000 ms idle. GET_STATUS was 1: U1/U2 device-initiated
flags were already clear. This does not establish host-initiated LPM policy.
The second report (11:49:01Z), device U1/U2 profile, failed claiming interface 0
(`interface not found`); no control feature or bulk command was issued. It is
not evidence that changing U1/U2 failed, nor does it prove why the interface
was absent. No chip read, programming or repeated cold-connect result is supplied yet.

Build 6 baseline at 2026-10-15T13:00:52Z and ordinary Connect both failed with
`claim interface 0: interface not found`; RUN reportedly blinked rapidly. The
device still enumerated as Super. No chip or bulk probe ran. This reproduces the
interface-publication failure independently of the optional U1/U2 experiment.

### Build 7: conditional initial configuration

[Apple's USB guide](https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/USBBook/USBDeviceInterfaces/USBDevInterfaces.html)
explains that vendor-specific devices can remain unconfigured until the app
selects a declared configuration, which creates the interface objects. nusb's
macOS claim path only searches existing interface objects. Its cached active
configuration is not definitive: failed configuration queries can become cached
zero. These facts make missing initial configuration a candidate; the user's
build 6 report did not measure it and cannot establish that cause.

Build 7 first tries the ordinary claim. Only on macOS T76, after a NotFound
claim, it reads standard GET_CONFIGURATION from the device (80/08/0000/0000,
length 1). If the response is exactly one byte zero, it selects the unique
declared nonzero configuration containing interface 0, alternate 0 and bulk
01/81. Selection uses nusb's OS API so macOS can publish its interfaces.
The value is read back and claim gets a fresh bounded retry window. There is
one selection attempt, no bus reset, no unconfigure request, and no bulk replay.
Busy, permission, unknown state, nonzero state and ambiguous descriptors never
trigger selection. Other platforms/models retain their claim behavior.

Diagnostics now collect BOS and configuration/endpoint descriptors before claim.
The `opening` report records enumerated interface numbers, cached state, actual
device state, selection/readback, typed claim-error categories and OS codes.
If configured state is nonzero but no interface appears, the report exposes
that mismatch instead of trying a reset or same-configuration reselect.
Hardware verification of this conditional recovery remains pending.

The normal transport maps an unavailable speed to High. The diagnostic records
the OS-reported speed independently, leaving it null when unavailable.

## Hypothesis: link power management

The historical BOS capture was
`050f160002071002060000000a1003000e00010aff07`: USB2 LPM/BESL, SuperSpeed
FS/HS/SS support, no LTM, U1 exit latency 10 µs and U2 exit latency 2047 µs.
These are advertised capabilities, not a trace of the link's runtime state.

[WCH's reference CH56x stack](https://github.com/hydrausb3/wch-ch56x-bsp/blob/main/usb/usb_devbulk/CH56x_usb30_devbulk.c)
handles link events in firmware. That makes a firmware/host LPM interaction
plausible; it does not prove the closed T76 firmware behaves identically.

Apple lists `kUSBHostDevicePropertyEnableLPM` and
`kUSBHostDevicePropertyDisablePortLPM` in its
[registry property names](https://developer.apple.com/documentation/usbdriverkit/registry-property-names).
No supported ordinary-app runtime setter was established in this investigation.
No supported public API was found to force this device to USB 2.0. Do not change
SIP, registry policy or shared hub ports as an automatic workaround.

## Implemented diagnostic experiments

Open **USB Diagnostics…** in the app sidebar or Programmer menu. Remove the
chip, connect exactly one T76 and unplug/replug before **each** test. Label the
connection, run the standard test first and save its JSON report. Reconnect,
then run the optional USB sleep experiment (advanced) if needed. The successful
Wavlink baseline requires no power-management workaround.

Equivalent bundled-helper commands:

```sh
"/Applications/XGecuPro.app/Contents/Resources/minipro" --json usb-diagnose
# Unplug/replug the T76 before the independent second test:
"/Applications/XGecuPro.app/Contents/Resources/minipro" --json usb-diagnose --disable-device-u1-u2
```

Diagnostics and ordinary opens now both preserve the host configuration.
The diagnostics read BOS/status and request system-info
four times, with idle intervals 0, 100, 1000 and 3000 ms. Ordinary bulk calls
retain 5-second deadlines. The first failed command stops the experiment;
there is no reset or retry. No chip commands, socket voltages, bitstreams or
firmware writes are involved. Reports omit serial numbers and chip contents.

The optional experiment reads the initial device status, clears only initially
enabled U1/U2 features, verifies the flags, runs system-info and attempts to
restore both initial flags even after partial setup or bulk failure. Reconnect
afterward, especially if restoration reports an error.

| EP0 operation | bmRequestType | bRequest | wValue | wIndex | wLength |
|---|---|---|---|---|---|
| GET_STATUS(device) | 0x80 | 0 | 0 | 0 | 2 |
| CLEAR_FEATURE(U1_ENABLE) | 0x00 | 1 | 48 | 0 | 0 |
| CLEAR_FEATURE(U2_ENABLE) | 0x00 | 1 | 49 | 0 | 0 |
| SET_FEATURE restore | 0x00 | 3 | 48 or 49 | 0 | 0 |

GET_STATUS is little-endian; U1 mask is 0x0004 and U2 mask is 0x0008.
[Linux Chapter 9 definitions](https://github.com/torvalds/linux/blob/master/include/uapi/linux/usb/ch9.h)
document the constants. Clearing these flags disables **device-initiated** entry;
host-initiated transitions can remain. It is not equivalent to disabling host LPM.
See [Microsoft's U1/U2 transition description](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/u1-and-u2-transitions).

JSON `ok` means a report was produced, including when no device opened. Inspect
`report.passed`, `report.error`, individual `probes` and `restore_error` for
the actual result. Passing system-info does not validate chip transfers or
enable SuperSpeed programming. The current build allows reads for validation.

## Next decisions after real hardware results

- Wavlink baseline passes: test build 6 normal Connect / Refresh repeatedly after
  cold connects, then read a full chip twice through Wavlink. Compare with a dump
  from the same unchanged chip through Digma. Reads already verify by a second
  full read; also compare the cross-route SHA-256 before enabling USB3 mutation.
- Only U1/U2 experiment passes: evaluate a scoped transport policy and test
  long reads, idle periods and reconnects before enabling it for chip operations.
- Neither passes: compare a native
  [IOUSBHost](https://developer.apple.com/documentation/iousbhost/) backend with
  nusb's current IOUSBLib backend. That A/B test has not been performed.
- Keep High Speed as a working fallback while diagnosing; a USB2-only cable
  can remove the extra Digma hub from the current chain.

Already tried without a repeatable SuperSpeed fix: SET_INTERFACE, configuration
reset/cycle, device reset, clear halt, reopen, control keepalives and first-touch
tests. Repeating these is not a new remedy. macOS CI can prove compilation,
packaging and mocked behavior, but has no T76 and cannot establish compatibility
with these docks. USB forwarding into a VM also does not prove the guest controls
the physical link's LPM policy; that requires evidence about the particular backend.
