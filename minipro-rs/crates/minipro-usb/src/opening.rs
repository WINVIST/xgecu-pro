//! Interface publication and scoped USB configuration compatibility handling.
use super::*;
use nusb::descriptors::TransferType;
use nusb::transfer::{ControlIn, ControlType, Recipient, TransferError};
use serde::Serialize;

#[derive(Debug, Default, Serialize)]
pub struct OpenReport {
    pub enumerated_interfaces: Vec<u8>,
    pub cached_configuration: Option<u8>,
    pub cached_configuration_error: Option<String>,
    pub configurations: Vec<Configuration>,
    pub device_configuration_before: Option<u8>,
    pub configuration_read_error: Option<String>,
    pub selected_configuration: Option<u8>,
    pub configuration_selection_reason: Option<&'static str>,
    pub configuration_set_error: Option<String>,
    pub configuration_readback_error: Option<String>,
    pub device_configuration_after: Option<u8>,
    pub interface_claimed: bool,
    pub claim_attempts: Vec<ClaimAttempt>,
}

#[derive(Debug, Serialize)]
pub struct Configuration {
    pub value: u8,
    pub interfaces: Vec<Interface>,
}

#[derive(Debug, Serialize)]
pub struct Interface {
    pub number: u8,
    pub alternate: u8,
    pub endpoints: Vec<EndpointDescription>,
}

#[derive(Debug, Serialize)]
pub struct EndpointDescription {
    pub address: u8,
    pub bulk: bool,
    pub max_packet_size: usize,
}

#[derive(Debug, Serialize)]
pub struct ClaimAttempt {
    pub kind: String,
    pub os_error: Option<u32>,
    pub message: String,
}

pub(super) fn describe(device: &nusb::Device, report: &mut OpenReport) {
    match device.active_configuration() {
        Ok(config) => report.cached_configuration = Some(config.configuration_value()),
        Err(e) => report.cached_configuration_error = Some(e.to_string()),
    }
    report.configurations = device
        .configurations()
        .map(|config| Configuration {
            value: config.configuration_value(),
            interfaces: config
                .interface_alt_settings()
                .map(|interface| Interface {
                    number: interface.interface_number(),
                    alternate: interface.alternate_setting(),
                    endpoints: interface
                        .endpoints()
                        .map(|ep| EndpointDescription {
                            address: ep.address(),
                            bulk: ep.transfer_type() == TransferType::Bulk,
                            max_packet_size: ep.max_packet_size(),
                        })
                        .collect(),
                })
                .collect(),
        })
        .collect();
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ConfigurationReadError {
    Stall,
    Failed(String),
}

impl std::fmt::Display for ConfigurationReadError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Stall => write!(f, "GET_CONFIGURATION: endpoint stalled"),
            Self::Failed(message) => write!(f, "{message}"),
        }
    }
}

type ConfigurationResult = std::result::Result<u8, ConfigurationReadError>;

pub(super) fn read_configuration(device: &nusb::Device) -> ConfigurationResult {
    let bytes = device
        .control_in(
            ControlIn {
                control_type: ControlType::Standard,
                recipient: Recipient::Device,
                request: 8,
                value: 0,
                index: 0,
                length: 1,
            },
            SHORT_TIMEOUT,
        )
        .wait()
        .map_err(|e| match e {
            TransferError::Stall => ConfigurationReadError::Stall,
            _ => ConfigurationReadError::Failed(format!("GET_CONFIGURATION: {e}")),
        })?;
    decode_configuration(&bytes)
}

fn decode_configuration(bytes: &[u8]) -> ConfigurationResult {
    match bytes {
        [value] => Ok(*value),
        _ => Err(ConfigurationReadError::Failed(format!(
            "GET_CONFIGURATION: expected 1 byte, got {}",
            bytes.len()
        ))),
    }
}

fn suitable_configurations(report: &OpenReport) -> Vec<u8> {
    report
        .configurations
        .iter()
        .filter(|config| {
            config.value != 0
                && config.interfaces.iter().any(|interface| {
                    interface.number == 0
                        && interface.alternate == 0
                        && [EP_CMD_OUT, EP_CMD_IN].into_iter().all(|address| {
                            interface
                                .endpoints
                                .iter()
                                .any(|ep| ep.address == address && ep.bulk)
                        })
                })
        })
        .map(|config| config.value)
        .collect()
}

struct ClaimFailure {
    kind: nusb::ErrorKind,
    detail: ClaimAttempt,
}

trait OpenIo {
    type Interface;
    fn claim(&self) -> std::result::Result<Self::Interface, ClaimFailure>;
    fn configuration(&self) -> ConfigurationResult;
    fn configure(&self, value: u8) -> Result<()>;
}

impl OpenIo for nusb::Device {
    type Interface = nusb::Interface;
    fn claim(&self) -> std::result::Result<Self::Interface, ClaimFailure> {
        self.claim_interface(0).wait().map_err(|e| ClaimFailure {
            kind: e.kind(),
            detail: ClaimAttempt {
                kind: format!("{:?}", e.kind()),
                os_error: e.os_error(),
                message: e.to_string(),
            },
        })
    }
    fn configuration(&self) -> ConfigurationResult {
        read_configuration(self)
    }
    fn configure(&self, value: u8) -> Result<()> {
        // Use the OS API, not raw SET_CONFIGURATION: IOKit must instantiate its
        // interface objects as well as selecting the USB device configuration.
        self.set_configuration(value)
            .wait()
            .map_err(|e| Error::Usb(format!("select configuration {value}: {e}")))
    }
}

pub(super) fn claim(
    device: &nusb::Device,
    allow_initial_configuration: bool,
    report: &mut OpenReport,
) -> Result<nusb::Interface> {
    claim_with(
        device,
        allow_initial_configuration,
        report,
        std::thread::sleep,
    )
}

fn claim_with<T: OpenIo>(
    device: &T,
    allow_initial_configuration: bool,
    report: &mut OpenReport,
    mut sleep: impl FnMut(Duration),
) -> Result<T::Interface> {
    let mut checked = false;
    let mut budget = CLAIM_ATTEMPTS;
    let mut attempt = 0;
    while attempt < budget {
        if attempt > 0 {
            sleep(CLAIM_RETRY_DELAY);
        }
        attempt += 1;
        match device.claim() {
            Ok(interface) => {
                report.interface_claimed = true;
                return Ok(interface);
            }
            Err(error) => {
                let missing = error.kind == nusb::ErrorKind::NotFound;
                let terminal = matches!(
                    error.kind,
                    nusb::ErrorKind::Disconnected | nusb::ErrorKind::PermissionDenied
                );
                report.claim_attempts.push(error.detail);
                if terminal {
                    break;
                }
                if missing && allow_initial_configuration && !checked {
                    checked = true;
                    match try_configuration(device, report) {
                        Ok(true) => budget = attempt + CLAIM_ATTEMPTS,
                        Ok(false) => {}
                        Err(()) => break,
                    }
                }
            }
        }
    }
    let last = report
        .claim_attempts
        .last()
        .map(|a| a.message.as_str())
        .unwrap_or("claim failed");
    Err(Error::Usb(format!(
        "claim interface 0: {last}; device configuration={:?}, cached={:?}, selected={:?}; configuration error={:?}; close other programmer apps, then reconnect the T76",
        report.device_configuration_before, report.cached_configuration, report.selected_configuration,
        report.configuration_set_error.as_ref().or(report.configuration_readback_error.as_ref()).or(report.configuration_read_error.as_ref()),
    )))
}

fn try_configuration<T: OpenIo>(
    device: &T,
    report: &mut OpenReport,
) -> std::result::Result<bool, ()> {
    let reason = match device.configuration() {
        Ok(value) => {
            report.device_configuration_before = Some(value);
            report.configuration_read_error = None;
            if value == 0 {
                Some("device_reported_zero")
            } else {
                None
            }
        }
        Err(error) => {
            let stalled = error == ConfigurationReadError::Stall;
            report.device_configuration_before = None;
            report.configuration_read_error = Some(error.to_string());
            // nusb 0.2.7 exposes cached zero as this error. Cached zero is not
            // proof of device state; combined with no host interfaces and an
            // explicit protocol STALL it permits one libusb-style compatibility
            // selection. Timeout/disconnect/short replies do not permit it.
            if stalled
                && report.enumerated_interfaces.is_empty()
                && report.cached_configuration.is_none()
                && report.cached_configuration_error.as_deref() == Some("device is not configured")
                && report.configurations.len() == 1
            {
                Some("get_configuration_stalled_no_host_interfaces")
            } else {
                None
            }
        }
    };
    let Some(reason) = reason else {
        return Ok(false);
    };
    let candidates = suitable_configurations(report);
    let [selected] = candidates.as_slice() else {
        report.configuration_set_error =
            Some("no unique declared configuration with interface 0 and bulk 01/81".into());
        return Err(());
    };
    report.selected_configuration = Some(*selected);
    report.configuration_selection_reason = Some(reason);
    if let Err(error) = device.configure(*selected) {
        report.configuration_set_error = Some(error.to_string());
        return Err(());
    }
    match device.configuration() {
        Ok(after) => {
            report.device_configuration_after = Some(after);
            if after != *selected {
                report.configuration_set_error = Some(format!(
                    "device reports configuration {after} after selecting {selected}"
                ));
                return Err(());
            }
        }
        Err(error) => {
            report.configuration_readback_error = Some(error.to_string());
            if error != ConfigurationReadError::Stall {
                return Err(());
            }
            // A device refusing this standard read can still expose working
            // interfaces after OS selection. Claim + command endpoints + actual
            // system-info exchange validate the usable path. Never select again.
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::VecDeque;

    struct Fake {
        claims: RefCell<VecDeque<&'static str>>,
        values: RefCell<VecDeque<ConfigurationResult>>,
        selected: RefCell<Vec<u8>>,
        fail_set: bool,
    }
    impl OpenIo for Fake {
        type Interface = ();
        fn claim(&self) -> std::result::Result<(), ClaimFailure> {
            let kind = self.claims.borrow_mut().pop_front().unwrap_or("NotFound");
            if kind == "ok" {
                return Ok(());
            }
            Err(ClaimFailure {
                kind: match kind {
                    "NotFound" => nusb::ErrorKind::NotFound,
                    "Busy" => nusb::ErrorKind::Busy,
                    "PermissionDenied" => nusb::ErrorKind::PermissionDenied,
                    _ => nusb::ErrorKind::Disconnected,
                },
                detail: ClaimAttempt {
                    kind: kind.into(),
                    os_error: None,
                    message: kind.into(),
                },
            })
        }
        fn configuration(&self) -> ConfigurationResult {
            self.values.borrow_mut().pop_front().unwrap_or_else(|| {
                Err(ConfigurationReadError::Failed(
                    "configuration read failed".into(),
                ))
            })
        }
        fn configure(&self, value: u8) -> Result<()> {
            self.selected.borrow_mut().push(value);
            if self.fail_set {
                Err(Error::Protocol)
            } else {
                Ok(())
            }
        }
    }
    fn fake(claims: &[&'static str], values: &[Option<u8>]) -> Fake {
        Fake {
            claims: RefCell::new(claims.iter().copied().collect()),
            values: RefCell::new(
                values
                    .iter()
                    .map(|value| {
                        value.ok_or_else(|| {
                            ConfigurationReadError::Failed("configuration read failed".into())
                        })
                    })
                    .collect(),
            ),
            selected: RefCell::new(vec![]),
            fail_set: false,
        }
    }
    fn report() -> OpenReport {
        OpenReport {
            configurations: vec![Configuration {
                value: 1,
                interfaces: vec![Interface {
                    number: 0,
                    alternate: 0,
                    endpoints: [EP_CMD_OUT, EP_CMD_IN]
                        .into_iter()
                        .map(|address| EndpointDescription {
                            address,
                            bulk: true,
                            max_packet_size: 1024,
                        })
                        .collect(),
                }],
            }],
            ..OpenReport::default()
        }
    }

    #[test]
    fn selects_declared_config_once_only_after_measured_zero_and_missing_interface() {
        let io = fake(&["NotFound", "NotFound", "ok"], &[Some(0), Some(1)]);
        let mut trace = report();
        claim_with(&io, true, &mut trace, |_| {}).unwrap();
        assert_eq!(*io.selected.borrow(), vec![1]);
        assert_eq!(trace.device_configuration_before, Some(0));
        assert_eq!(trace.device_configuration_after, Some(1));
    }

    #[test]
    fn never_reconfigures_working_busy_nonzero_unknown_or_out_of_scope_device() {
        for (claims, values, allowed) in [
            (vec!["ok"], vec![], true),
            (vec!["Busy", "ok"], vec![Some(0)], true),
            (vec!["NotFound"], vec![Some(1)], true),
            (vec!["NotFound"], vec![None], true),
            (vec!["NotFound"], vec![Some(0)], false),
            (vec!["PermissionDenied"], vec![Some(0)], true),
        ] {
            let io = fake(&claims, &values);
            let _ = claim_with(&io, allowed, &mut report(), |_| {});
            assert!(io.selected.borrow().is_empty());
        }
    }

    #[test]
    fn configuration_selection_failure_or_wrong_readback_is_not_retried() {
        for (fail_set, readback) in [(true, Some(1)), (false, Some(0)), (false, None)] {
            let mut io = fake(&["NotFound", "ok"], &[Some(0), readback]);
            io.fail_set = fail_set;
            let mut trace = report();
            assert!(claim_with(&io, true, &mut trace, |_| {}).is_err());
            assert_eq!(*io.selected.borrow(), vec![1]);
            assert_eq!(trace.claim_attempts.len(), 1);
        }
    }

    #[test]
    fn ambiguous_or_incorrect_descriptors_never_select_a_configuration() {
        for ambiguous in [true, false] {
            let io = fake(&["NotFound"], &[Some(0)]);
            let mut trace = report();
            if ambiguous {
                trace.configurations.push(Configuration {
                    value: 2,
                    interfaces: std::mem::take(&mut report().configurations[0].interfaces),
                });
            } else {
                trace.configurations[0].interfaces[0].endpoints[0].bulk = false;
            }
            assert!(claim_with(&io, true, &mut trace, |_| {}).is_err());
            assert!(io.selected.borrow().is_empty());
        }
    }

    #[test]
    fn configuration_response_requires_exactly_one_byte() {
        for bytes in [&[][..], &[0, 0][..]] {
            assert!(decode_configuration(bytes).is_err());
        }
        assert_eq!(decode_configuration(&[0]).unwrap(), 0);
        assert_eq!(decode_configuration(&[1]).unwrap(), 1);
    }

    #[test]
    fn configured_missing_interface_keeps_evidence_and_bounds_claim_attempts() {
        let io = fake(&["NotFound"], &[Some(1)]);
        let mut trace = report();
        trace.cached_configuration = Some(1);
        assert!(claim_with(&io, true, &mut trace, |_| {}).is_err());
        assert_eq!(trace.device_configuration_before, Some(1));
        assert_eq!(trace.claim_attempts.len(), CLAIM_ATTEMPTS as usize);
        assert_eq!(trace.configurations.len(), 1);
        assert!(io.selected.borrow().is_empty());
    }

    #[test]
    fn selects_the_descriptor_value_instead_of_hardcoding_one() {
        let io = fake(&["NotFound", "ok"], &[Some(0), Some(7)]);
        let mut trace = report();
        trace.configurations[0].value = 7;
        claim_with(&io, true, &mut trace, |_| {}).unwrap();
        assert_eq!(*io.selected.borrow(), vec![7]);
    }

    fn stalled_fixture(
        claims: &[&'static str],
        readback: ConfigurationResult,
    ) -> (Fake, OpenReport) {
        let io = fake(claims, &[]);
        *io.values.borrow_mut() = [Err(ConfigurationReadError::Stall), readback]
            .into_iter()
            .collect();
        let mut trace = report();
        trace.cached_configuration_error = Some("device is not configured".into());
        (io, trace)
    }

    #[test]
    fn stalled_configuration_gets_one_scoped_compatibility_selection() {
        for readback in [Ok(1), Err(ConfigurationReadError::Stall)] {
            let (io, mut trace) = stalled_fixture(&["NotFound", "NotFound", "ok"], readback);
            claim_with(&io, true, &mut trace, |_| {}).unwrap();
            assert_eq!(*io.selected.borrow(), vec![1]);
            assert_eq!(trace.device_configuration_before, None);
            assert_eq!(
                trace.configuration_selection_reason,
                Some("get_configuration_stalled_no_host_interfaces")
            );
            assert!(trace.interface_claimed);
        }
    }

    #[test]
    fn stall_does_not_override_active_host_interfaces_or_ambiguous_descriptors() {
        for case in 0..5 {
            let (io, mut trace) = stalled_fixture(&["NotFound"], Ok(1));
            match case {
                0 => trace.enumerated_interfaces.push(0),
                1 => trace.cached_configuration = Some(1),
                2 => {
                    trace.cached_configuration_error =
                        Some("no descriptor found for active configuration 2".into())
                }
                3 => trace.configurations.push(Configuration {
                    value: 2,
                    interfaces: vec![],
                }),
                _ => trace.configurations[0].interfaces[0].endpoints.clear(),
            }
            assert!(claim_with(&io, true, &mut trace, |_| {}).is_err());
            assert!(io.selected.borrow().is_empty());
        }
    }

    #[test]
    fn compatibility_selection_does_not_repeat_when_interface_stays_absent() {
        let (io, mut trace) = stalled_fixture(&["NotFound"], Err(ConfigurationReadError::Stall));
        assert!(claim_with(&io, true, &mut trace, |_| {}).is_err());
        assert_eq!(*io.selected.borrow(), vec![1]);
        assert!(!trace.interface_claimed);
        assert_eq!(trace.claim_attempts.len(), (CLAIM_ATTEMPTS + 1) as usize);
    }

    #[test]
    fn compatibility_readback_error_or_mismatch_does_not_accept_interface() {
        for readback in [
            Ok(0),
            Ok(2),
            Err(ConfigurationReadError::Failed("disconnected".into())),
        ] {
            let (io, mut trace) = stalled_fixture(&["NotFound", "ok"], readback);
            assert!(claim_with(&io, true, &mut trace, |_| {}).is_err());
            assert_eq!(*io.selected.borrow(), vec![1]);
            assert!(!trace.interface_claimed);
        }
    }

    #[test]
    fn stalled_query_never_configures_an_out_of_scope_device() {
        let (io, mut trace) = stalled_fixture(&["NotFound"], Ok(1));
        assert!(claim_with(&io, false, &mut trace, |_| {}).is_err());
        assert!(io.selected.borrow().is_empty());
    }

    #[test]
    fn other_configuration_failures_never_use_the_stall_fallback() {
        for message in [
            "timeout",
            "disconnected",
            "short reply",
            "unsupported OS argument",
        ] {
            let (io, mut trace) = stalled_fixture(&["NotFound"], Ok(1));
            io.values.borrow_mut()[0] = Err(ConfigurationReadError::Failed(message.into()));
            assert!(claim_with(&io, true, &mut trace, |_| {}).is_err());
            assert!(io.selected.borrow().is_empty());
        }
    }
}
