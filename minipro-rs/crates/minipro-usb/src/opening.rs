//! Interface publication and strictly conditional initial USB configuration.
use super::*;
use nusb::descriptors::TransferType;
use nusb::transfer::{ControlIn, ControlType, Recipient};
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
    pub configuration_set_error: Option<String>,
    pub device_configuration_after: Option<u8>,
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

pub(super) fn read_configuration(device: &nusb::Device) -> Result<u8> {
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
        .map_err(|e| Error::Usb(format!("GET_CONFIGURATION: {e}")))?;
    decode_configuration(&bytes)
}

fn decode_configuration(bytes: &[u8]) -> Result<u8> {
    match bytes {
        [value] => Ok(*value),
        _ => Err(Error::Usb(format!(
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
    fn configuration(&self) -> Result<u8>;
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
    fn configuration(&self) -> Result<u8> {
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
            Ok(interface) => return Ok(interface),
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
                    match device.configuration() {
                        Ok(value) => {
                            report.device_configuration_before = Some(value);
                            report.configuration_read_error = None;
                            if value == 0 {
                                let candidates = suitable_configurations(report);
                                let [selected] = candidates.as_slice() else {
                                    report.configuration_set_error = Some("unconfigured T76 has no unique declared configuration with interface 0 and bulk 01/81".into());
                                    break;
                                };
                                report.selected_configuration = Some(*selected);
                                if let Err(e) = device.configure(*selected) {
                                    report.configuration_set_error = Some(e.to_string());
                                    break;
                                }
                                match device.configuration() {
                                    Ok(after) => {
                                        report.device_configuration_after = Some(after);
                                        if after != *selected {
                                            report.configuration_set_error = Some(format!("device reports configuration {after} after selecting {selected}"));
                                            break;
                                        }
                                    }
                                    Err(e) => {
                                        report.configuration_read_error = Some(e.to_string());
                                        break;
                                    }
                                }
                                // Give the OS a fresh bounded claim window after
                                // configuration. No reset, no 1->0, no reselect.
                                budget = attempt + CLAIM_ATTEMPTS;
                            }
                        }
                        Err(e) => report.configuration_read_error = Some(e.to_string()),
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
        report.configuration_set_error.as_ref().or(report.configuration_read_error.as_ref()),
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::collections::VecDeque;

    struct Fake {
        claims: RefCell<VecDeque<&'static str>>,
        values: RefCell<VecDeque<Option<u8>>>,
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
        fn configuration(&self) -> Result<u8> {
            self.values
                .borrow_mut()
                .pop_front()
                .flatten()
                .ok_or(Error::Protocol)
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
            values: RefCell::new(values.iter().copied().collect()),
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
}
