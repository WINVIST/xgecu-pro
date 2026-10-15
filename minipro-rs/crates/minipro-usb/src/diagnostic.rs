//! Bounded T76 USB experiments. Never exposes an unguarded programmer to chip
//! operations: only EP0 status/features/BOS and the read-only system-info command.
use super::*;
use minipro_core::error::FwVersion;
use nusb::transfer::{ControlIn, ControlOut, ControlType, Recipient};
use serde::Serialize;

const U1: u16 = 0x0004;
const U2: u16 = 0x0008;
const IDLE_MS: [u64; 4] = [0, 100, 1_000, 3_000];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Profile {
    Baseline,
    /// Prevent device-initiated U1/U2 only. Host-initiated entry may remain.
    DeviceU1U2Disabled,
}

impl Profile {
    pub fn name(self) -> &'static str {
        match self {
            Self::Baseline => "baseline",
            Self::DeviceU1U2Disabled => "device-u1-u2-disabled",
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub profile: &'static str,
    /// True only if all four system-info probes and feature restoration pass.
    /// This is not a chip read/write validation or permission to bypass guards.
    pub passed: bool,
    pub link: Option<String>,
    pub status_before: Option<u16>,
    pub status_during: Option<u16>,
    pub status_restored: Option<u16>,
    pub bos_hex: Option<String>,
    pub command_out_packet_size: Option<usize>,
    pub command_in_packet_size: Option<usize>,
    pub probes: Vec<Probe>,
    pub notes: Vec<String>,
    pub error: Option<String>,
    pub restore_error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Probe {
    pub idle_ms: u64,
    pub elapsed_ms: u128,
    pub firmware: Option<String>,
    pub error: Option<String>,
}

/// One physical T76 must be connected. Errors are data so the GUI can export a
/// failed probe too. No serial, device-code, manufacturing date or raw identity
/// response is included. Unplug/replug before each independent experiment.
pub fn diagnose_t76(profile: Profile) -> Report {
    let mut report = Report {
        profile: profile.name(),
        passed: false,
        link: None,
        status_before: None,
        status_during: None,
        status_restored: None,
        bos_hex: None,
        command_out_packet_size: None,
        command_in_packet_size: None,
        probes: Vec::new(),
        notes: Vec::new(),
        error: None,
        restore_error: None,
    };
    if let Err(error) = diagnose(profile, &mut report) {
        report.error = Some(error.to_string());
    }
    report
}

fn diagnose(profile: Profile, report: &mut Report) -> Result<()> {
    // Record the OS-reported speed separately: the normal transport maps an
    // unavailable speed to High, which must not be presented as a measurement.
    let mut devices = nusb::list_devices()
        .wait()
        .map_err(|e| Error::Usb(format!("enumerate: {e}")))?
        .filter(|d| d.vendor_id() == T76_VID && d.product_id() == T76_PID);
    let info = devices
        .next()
        .ok_or_else(|| Error::Usb("no T76 connected".into()))?;
    if devices.next().is_some() {
        return Err(Error::Usb(
            "connect exactly one T76 for USB diagnostics".into(),
        ));
    }
    let speed = info.speed();
    report.link = speed.map(|s| format!("{s:?}"));
    if profile == Profile::DeviceU1U2Disabled
        && !matches!(speed, Some(Speed::Super | Speed::SuperPlus))
    {
        return Err(Error::Usb(
            "device U1/U2 experiment requires a confirmed SuperSpeed link".into(),
        ));
    }
    // Sole also checks the second enumeration. No serial is embedded in errors
    // or the exported report; this path performs no chip operation.
    let (device, interface, link, serial) =
        open_device_with_policy(T76_VID, T76_PID, Select::Sole, false)?;
    let mut tx = UsbTransport {
        device,
        interface: Some(interface),
        out_eps: HashMap::new(),
        in_eps: HashMap::new(),
        link,
        vid: T76_VID,
        pid: T76_PID,
        serial,
    };
    report.command_out_packet_size = Some(tx.out_ep(EP_CMD_OUT)?.max_packet_size());
    report.command_in_packet_size = Some(tx.in_ep(EP_CMD_IN)?.max_packet_size());
    match tx.device.get_descriptor(15, 0, 0, SHORT_TIMEOUT).wait() {
        Ok(bytes) => report.bos_hex = Some(bytes.iter().map(|b| format!("{b:02x}")).collect()),
        Err(e) => report.notes.push(format!("BOS read unavailable: {e}")),
    }
    match tx.status() {
        Ok(status) => report.status_before = Some(status),
        Err(e) if profile == Profile::Baseline => report.notes.push(e.to_string()),
        Err(e) => return Err(e),
    }
    run_experiment(&mut tx, profile, report, std::thread::sleep)
}

trait DiagnosticTransport: Transport {
    fn status(&self) -> Result<u16>;
    fn feature(&self, request: u8, selector: u16) -> Result<()>;
}

fn run_experiment(
    tx: &mut impl DiagnosticTransport,
    profile: Profile,
    report: &mut Report,
    sleep: impl FnMut(Duration),
) -> Result<()> {
    // Always attempt restoration even when one clear or the bulk exchange
    // fails. Only flags initially enabled are cleared and later restored.
    let original = report.status_before.unwrap_or(0);
    let experiment = (|| {
        if profile == Profile::DeviceU1U2Disabled {
            if original & (U1 | U2) == 0 {
                report.notes.push("Device U1/U2 flags were already disabled; this profile made no feature change.".into());
            }
            for selector in enabled_features(original) {
                tx.feature(1, selector)?;
            }
            let status = tx.status()?;
            report.status_during = Some(status);
            if status & (U1 | U2) != 0 {
                return Err(Error::Usb("device U1/U2 flags stayed enabled".into()));
            }
            report.notes.push(
                "Device-initiated U1/U2 disabled; host-initiated transitions may remain enabled."
                    .into(),
            );
        }
        report.probes = probe_info(tx, sleep);
        Ok(())
    })();
    if profile == Profile::DeviceU1U2Disabled {
        let mut errors = Vec::new();
        for selector in enabled_features(original) {
            if let Err(e) = tx.feature(3, selector) {
                errors.push(e.to_string());
            }
        }
        match tx.status() {
            Ok(status) => {
                report.status_restored = Some(status);
                if status & (U1 | U2) != original & (U1 | U2) {
                    errors.push("device U1/U2 flags did not return to their initial values".into());
                }
            }
            Err(e) => errors.push(e.to_string()),
        }
        if !errors.is_empty() {
            report.restore_error = Some(errors.join("; "));
        }
    }
    experiment?;
    report.passed = report.probes.len() == IDLE_MS.len()
        && report.probes.iter().all(|p| p.error.is_none())
        && report.restore_error.is_none();
    Ok(())
}

fn enabled_features(status: u16) -> impl Iterator<Item = u16> {
    [(U1, 48), (U2, 49)]
        .into_iter()
        .filter_map(move |(mask, selector)| (status & mask != 0).then_some(selector))
}

impl DiagnosticTransport for UsbTransport {
    fn status(&self) -> Result<u16> {
        let bytes = self
            .device
            .control_in(
                ControlIn {
                    control_type: ControlType::Standard,
                    recipient: Recipient::Device,
                    request: 0,
                    value: 0,
                    index: 0,
                    length: 2,
                },
                SHORT_TIMEOUT,
            )
            .wait()
            .map_err(|e| Error::Usb(format!("GET_STATUS(device): {e}")))?;
        match bytes.as_slice() {
            [lo, hi] => Ok(u16::from_le_bytes([*lo, *hi])),
            _ => Err(Error::Usb(format!(
                "GET_STATUS(device): expected 2 bytes, got {}",
                bytes.len()
            ))),
        }
    }

    fn feature(&self, request: u8, selector: u16) -> Result<()> {
        self.device
            .control_out(
                ControlOut {
                    control_type: ControlType::Standard,
                    recipient: Recipient::Device,
                    request,
                    value: selector,
                    index: 0,
                    data: &[],
                },
                SHORT_TIMEOUT,
            )
            .wait()
            .map_err(|e| {
                Error::Usb(format!(
                    "device feature request {request} selector {selector}: {e}"
                ))
            })
    }
}

fn probe_info(tx: &mut dyn Transport, mut sleep: impl FnMut(Duration)) -> Vec<Probe> {
    let mut probes = Vec::new();
    for idle_ms in IDLE_MS {
        sleep(Duration::from_millis(idle_ms));
        let started = std::time::Instant::now();
        let result = (|| {
            tx.send(Ep(EP_CMD_OUT), &[0; 5])?;
            let reply = tx.recv(Ep(EP_CMD_IN), 64)?; // drain every accepted request
            if reply.len() != 64 || reply[6] != 8 || (reply[4] == 0 && reply[5] == 0) {
                return Err(Error::Usb(
                    "unexpected T76 system-info reply (normal firmware required)".into(),
                ));
            }
            Ok(FwVersion(((reply[5] as u32) << 8) | reply[4] as u32).to_string())
        })();
        let (firmware, error) = match result {
            Ok(fw) => (Some(fw), None),
            Err(e) => (None, Some(e.to_string())),
        };
        let failed = error.is_some();
        probes.push(Probe {
            idle_ms,
            elapsed_ms: started.elapsed().as_millis(),
            firmware,
            error,
        });
        if failed {
            break;
        } // no reset/retry on a potentially wedged device
    }
    probes
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    struct PowerMock {
        status: RefCell<u16>,
        requests: RefCell<Vec<(u8, u16)>>,
        fail_clear_u2: bool,
        tx: MockTransport,
    }

    impl Transport for PowerMock {
        fn send(&mut self, ep: Ep, data: &[u8]) -> Result<()> {
            self.tx.send(ep, data)
        }
        fn recv(&mut self, ep: Ep, len: usize) -> Result<Vec<u8>> {
            self.tx.recv(ep, len)
        }
        fn link_speed(&self) -> LinkSpeed {
            LinkSpeed::Super
        }
        fn reset(&mut self) -> Result<()> {
            Err(Error::Protocol)
        }
    }

    impl DiagnosticTransport for PowerMock {
        fn status(&self) -> Result<u16> {
            Ok(*self.status.borrow())
        }
        fn feature(&self, request: u8, selector: u16) -> Result<()> {
            self.requests.borrow_mut().push((request, selector));
            if self.fail_clear_u2 && request == 1 && selector == 49 {
                return Err(Error::Protocol);
            }
            let mask = if selector == 48 { U1 } else { U2 };
            if request == 1 {
                *self.status.borrow_mut() &= !mask;
            } else {
                *self.status.borrow_mut() |= mask;
            }
            Ok(())
        }
    }

    fn empty_report() -> Report {
        Report {
            profile: "test",
            passed: false,
            link: None,
            status_before: Some(U1 | U2),
            status_during: None,
            status_restored: None,
            bos_hex: None,
            command_out_packet_size: None,
            command_in_packet_size: None,
            probes: vec![],
            notes: vec![],
            error: None,
            restore_error: None,
        }
    }

    #[test]
    fn features_restored_after_partial_setup_or_bulk_failure() {
        for fail_clear_u2 in [true, false] {
            let mut tx = PowerMock {
                status: RefCell::new(U1 | U2),
                requests: RefCell::new(vec![]),
                fail_clear_u2,
                tx: MockTransport::from_script(vec![]),
            };
            let mut report = empty_report();
            let result = run_experiment(&mut tx, Profile::DeviceU1U2Disabled, &mut report, |_| {});
            assert_eq!(result.is_err(), fail_clear_u2);
            assert_eq!(report.status_restored, Some(U1 | U2));
            assert!(!report.passed);
            assert!(report.restore_error.is_none());
            assert_eq!(
                *tx.requests.borrow(),
                vec![(1, 48), (1, 49), (3, 48), (3, 49)]
            );
        }
    }

    #[test]
    fn baseline_never_changes_power_features() {
        let mut tx = PowerMock {
            status: RefCell::new(U1 | U2),
            requests: RefCell::new(vec![]),
            fail_clear_u2: true,
            tx: MockTransport::from_script(vec![(vec![0; 5], reply()); 4]),
        };
        let mut report = empty_report();
        run_experiment(&mut tx, Profile::Baseline, &mut report, |_| {}).unwrap();
        assert!(report.passed);
        assert!(tx.requests.borrow().is_empty());
    }

    #[test]
    fn feature_masks_ignore_remote_wakeup_and_ltm() {
        assert_eq!(
            enabled_features(0x0013).collect::<Vec<_>>(),
            Vec::<u16>::new()
        );
        assert_eq!(enabled_features(0x0004).collect::<Vec<_>>(), vec![48]);
        assert_eq!(enabled_features(0x0008).collect::<Vec<_>>(), vec![49]);
        assert_eq!(enabled_features(0x001f).collect::<Vec<_>>(), vec![48, 49]);
    }

    fn reply() -> Vec<u8> {
        let mut r = vec![0; 64];
        r[4] = 18;
        r[5] = 1;
        r[6] = 8;
        r
    }

    #[test]
    fn repeated_probe_drains_replies_and_covers_idle_intervals() {
        let mut tx = MockTransport::from_script(vec![(vec![0; 5], reply()); 4]);
        let mut delays = Vec::new();
        let probes = probe_info(&mut tx, |duration| delays.push(duration.as_millis()));
        assert_eq!(delays, vec![0, 100, 1000, 3000]);
        assert!(probes
            .iter()
            .all(|p| p.firmware.as_deref() == Some("00.1.18") && p.error.is_none()));
        assert_eq!(tx.pos, 4);
    }

    #[test]
    fn bad_or_short_reply_stops_before_next_command() {
        for bad in [vec![], vec![0; 6], vec![0; 64], vec![0; 65]] {
            let mut tx = MockTransport::from_script(vec![(vec![0; 5], bad), (vec![0; 5], reply())]);
            let probes = probe_info(&mut tx, |_| {});
            assert_eq!(probes.len(), 1);
            assert!(probes[0].error.is_some());
            assert_eq!(tx.pos, 1);
        }
    }

    #[test]
    fn out_failure_does_not_read_or_retry() {
        let mut tx = MockTransport::from_script(vec![(vec![1], reply())]);
        let probes = probe_info(&mut tx, |_| {});
        assert_eq!(probes.len(), 1);
        assert!(probes[0].error.is_some());
        assert_eq!(tx.pos, 0);
    }
}
