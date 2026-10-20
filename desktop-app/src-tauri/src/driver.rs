//! Read-only Windows driver detection. Binding changes are always performed by
//! the owner using the documented setup/restore procedure, outside this app.
use crate::error::Result;

pub fn precheck() -> Result<()> {
    #[cfg(windows)]
    {
        use nusb::MaybeFuture;
        let devices = nusb::list_devices().wait().map_err(|error| {
            crate::error::BridgeError::new(
                "driver_enumeration",
                format!("Could not inspect the T76 USB driver: {error}"),
            )
        })?;
        for device in
            devices.filter(|device| device.vendor_id() == 0xa466 && device.product_id() == 0x1a86)
        {
            validate_driver(device.driver())?;
        }
    }
    Ok(())
}

#[cfg(any(windows, test))]
fn validate_driver(driver: Option<&str>) -> Result<()> {
    // usbccgp is the composite parent; nusb subsequently checks the individual
    // WinUSB interface while opening it. A whole-device binding must be WinUSB.
    if driver.is_some_and(|name| {
        name.eq_ignore_ascii_case("WinUSB") || name.eq_ignore_ascii_case("usbccgp")
    }) {
        return Ok(());
    }
    Err(crate::error::BridgeError::new("driver_incompatible", format!("The T76 USB driver is {}. XGecu Pro requires WinUSB.", driver.unwrap_or("not installed")))
        .hint("Open USB Diagnostics > USB setup and recovery for the T76 a466:1a86 installation and restore steps. The app does not replace drivers automatically."))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn winusb_and_composite_parent_are_supported_without_changing_bindings() {
        assert!(validate_driver(Some("WinUSB")).is_ok());
        assert!(validate_driver(Some("winusb")).is_ok());
        assert!(validate_driver(Some("usbccgp")).is_ok());
        assert_eq!(
            validate_driver(None).unwrap_err().code,
            "driver_incompatible"
        );
        assert_eq!(
            validate_driver(Some("libusb0")).unwrap_err().code,
            "driver_incompatible"
        );
    }
}
