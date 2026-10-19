use crate::error::{BridgeError, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    ffi::OsString,
    path::{Path, PathBuf},
};

pub const MAX_IMAGE_BYTES: u64 = 2 * 1024 * 1024 * 1024;

#[derive(Debug, Serialize)]
pub struct FileInfo {
    pub bytes: u64,
}

pub fn inspect_image(value: &str) -> Result<FileInfo> {
    let path = input_file(Some(value))?;
    let metadata = std::fs::File::open(&path)?.metadata()?;
    if !metadata.is_file() {
        return Err(BridgeError::new(
            "invalid_file",
            "The programming image is not a regular file.",
        ));
    }
    let limit = if input_format(&path) == "raw" {
        MAX_IMAGE_BYTES
    } else {
        8 * 1024 * 1024 * 1024
    };
    if metadata.len() == 0 {
        return Err(BridgeError::new(
            "empty_image",
            "The programming image is empty.",
        ));
    }
    if metadata.len() > limit {
        return Err(BridgeError::new(
            "image_too_large",
            "The programming image exceeds its size limit.",
        ));
    }
    Ok(FileInfo {
        bytes: metadata.len(),
    })
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Operation {
    Connect,
    Search,
    Describe,
    Autodetect,
    Check,
    Read,
    Verify,
    Blank,
    Erase,
    UsbDiagnose,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProgrammerRequest {
    pub operation: Operation,
    pub chip: Option<String>,
    pub query: Option<String>,
    pub file: Option<String>,
    pub database: Option<String>,
    pub limit: Option<u32>,
    pub disable_device_u1_u2: Option<bool>,
}

pub fn chip_name(chip: Option<&str>) -> Result<&str> {
    chip.filter(|s| {
        !s.trim().is_empty()
            && s.len() <= 512
            && !s.starts_with('-')
            && !s.chars().any(char::is_control)
    })
    .ok_or_else(|| BridgeError::new("invalid_chip", "Select an exact chip from the database."))
}

pub fn input_format(path: &Path) -> &'static str {
    if path.extension().and_then(|s| s.to_str()).is_some_and(|s| {
        ["bin", "rom", "raw"]
            .iter()
            .any(|ext| s.eq_ignore_ascii_case(ext))
    }) {
        "raw"
    } else {
        "auto"
    }
}

pub fn input_file(value: Option<&str>) -> Result<PathBuf> {
    let path = value
        .filter(|s| !s.is_empty())
        .ok_or_else(|| BridgeError::new("invalid_file", "Choose an image file."))?;
    let selected = Path::new(path);
    let target = std::fs::canonicalize(selected)?;
    if !target.is_file() {
        return Err(BridgeError::new(
            "invalid_file",
            "The image is not a regular file.",
        ));
    }
    // Input format belongs to the name the owner selected. Resolving a final
    // firmware.bin -> payload.hex link must not turn literal bytes into text
    // records (or do the reverse). Resolve only the directory for the returned
    // absolute path, after independently validating the canonical target.
    let name = selected
        .file_name()
        .ok_or_else(|| BridgeError::new("invalid_file", "Choose an image filename."))?;
    let parent = selected
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    Ok(std::fs::canonicalize(parent)?.join(name))
}

pub fn output_file(value: Option<&str>) -> Result<PathBuf> {
    let path = Path::new(
        value
            .filter(|s| !s.is_empty())
            .ok_or_else(|| BridgeError::new("invalid_file", "Choose a destination file."))?,
    );
    let name = path
        .file_name()
        .ok_or_else(|| BridgeError::new("invalid_file", "Choose a destination filename."))?;
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let result = std::fs::canonicalize(parent)?.join(name);
    if result.is_dir() {
        return Err(BridgeError::new(
            "invalid_file",
            "The destination is a directory.",
        ));
    }
    Ok(result)
}

pub fn enforce_capability(details: &Value, chip: &str, mutation: bool, erase: bool) -> Result<()> {
    let readable = details["name"].as_str() == Some(chip)
        && details["package"].as_str().is_some_and(|s| !s.is_empty())
        && details["pins"].as_u64().is_some_and(|n| n > 0)
        && details["code_bytes"]
            .as_u64()
            .is_some_and(|n| n > 0 && n <= MAX_IMAGE_BYTES)
        && ["data_bytes", "data2_bytes", "page_bytes"]
            .iter()
            .all(|key| details[key].as_u64().is_some());
    if !readable {
        return Err(BridgeError::new(
            "unsupported_chip",
            "Select a database chip with a code region of 1 byte to 2 GiB.",
        ));
    }
    if mutation
        && !details["chip_id"]
            .as_str()
            .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err(BridgeError::new(
            "chip_id_required",
            "Programming and erase require a database electronic ID.",
        ));
    }
    if erase && details["can_erase"].as_bool() != Some(true) {
        return Err(BridgeError::new(
            "erase_unsupported",
            "The selected chip is not electrically erasable.",
        ));
    }
    Ok(())
}

pub fn arguments(request: &ProgrammerRequest) -> Result<Vec<OsString>> {
    let mut args: Vec<OsString> = Vec::new();
    match request.operation {
        Operation::Connect => args.push("info".into()),
        Operation::Search => {
            let query = request.query.as_deref().unwrap_or("");
            if query.len() > 512 || query.starts_with('-') || query.chars().any(char::is_control) {
                return Err(BridgeError::new(
                    "invalid_query",
                    "Enter a chip name or package to search.",
                ));
            }
            let limit = request.limit.unwrap_or(1_000_000);
            if limit > 1_000_000 {
                return Err(BridgeError::new(
                    "invalid_limit",
                    "Catalog limit exceeds one million chips.",
                ));
            }
            args.extend([
                "search".into(),
                query.into(),
                "--limit".into(),
                limit.to_string().into(),
            ]);
        }
        Operation::Autodetect => args.extend(["autodetect".into(), "--wide".into()]),
        Operation::UsbDiagnose => {
            args.push("usb-diagnose".into());
            if request.disable_device_u1_u2.unwrap_or(false) {
                args.push("--disable-device-u1-u2".into());
            }
        }
        operation => {
            let chip = chip_name(request.chip.as_deref())?;
            let command = match operation {
                Operation::Describe => "describe",
                Operation::Check => "check",
                Operation::Read => "read",
                Operation::Verify => "verify",
                Operation::Blank => "blank",
                Operation::Erase => "erase",
                _ => {
                    return Err(BridgeError::new(
                        "invalid_operation",
                        "Unsupported operation.",
                    ))
                }
            };
            args.extend([command.into(), chip.into()]);
            if operation == Operation::Read {
                args.push(output_file(request.file.as_deref())?.into_os_string());
            } else if operation == Operation::Verify {
                let file = input_file(request.file.as_deref())?;
                let format = input_format(&file);
                args.extend([file.into_os_string(), "--format".into(), format.into()]);
            }
        }
    }
    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn details() -> Value {
        json!({"name":"TEST@DIP8","package":"DIP8","pins":8,"code_bytes":MAX_IMAGE_BYTES,"data_bytes":0,"data2_bytes":0,"page_bytes":256,"chip_id":"1234","can_erase":true})
    }
    #[test]
    fn policy_rejects_missing_id_unsupported_erase_and_large_region() {
        let mut d = details();
        assert!(enforce_capability(&d, "TEST@DIP8", true, true).is_ok());
        d["chip_id"] = Value::Null;
        assert_eq!(
            enforce_capability(&d, "TEST@DIP8", true, false)
                .unwrap_err()
                .code,
            "chip_id_required"
        );
        assert!(enforce_capability(&d, "TEST@DIP8", false, false).is_ok());
        d = details();
        d["can_erase"] = json!(false);
        assert_eq!(
            enforce_capability(&d, "TEST@DIP8", true, true)
                .unwrap_err()
                .code,
            "erase_unsupported"
        );
        d["code_bytes"] = json!(MAX_IMAGE_BYTES + 1);
        assert!(enforce_capability(&d, "TEST@DIP8", false, false).is_err());
    }
    #[test]
    fn requests_cannot_add_cli_escape_hatches() {
        assert!(serde_json::from_value::<ProgrammerRequest>(
            json!({"operation":"write","force":true})
        )
        .is_err());
        assert!(serde_json::from_value::<ProgrammerRequest>(
            json!({"operation":"erase","chip":"TEST","force":true})
        )
        .is_err());
        assert!(chip_name(Some("--force")).is_err());
    }
    #[test]
    fn firmware_metadata_is_readable_bounded_and_preserves_the_source() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("прошивка.bin");
        std::fs::write(&path, b"firmware").unwrap();
        assert_eq!(inspect_image(path.to_str().unwrap()).unwrap().bytes, 8);
        assert_eq!(std::fs::read(&path).unwrap(), b"firmware");
        std::fs::File::create(&path)
            .unwrap()
            .set_len(MAX_IMAGE_BYTES + 1)
            .unwrap();
        assert_eq!(
            inspect_image(path.to_str().unwrap()).unwrap_err().code,
            "image_too_large"
        );
        assert!(inspect_image(directory.path().to_str().unwrap()).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn selected_symlink_extension_controls_raw_and_text_verification_formats() {
        use std::os::unix::fs::symlink;
        let directory = tempfile::tempdir().unwrap();
        for (selected_name, target_name, expected_format) in [
            ("firmware.bin", "payload.hex", "raw"),
            ("firmware.hex", "payload.bin", "auto"),
        ] {
            let target = directory.path().join(target_name);
            std::fs::write(&target, b":03000000010203F7\n:00000001FF\n").unwrap();
            let selected = directory.path().join(selected_name);
            symlink(&target, &selected).unwrap();
            let input = input_file(selected.to_str()).unwrap();
            assert_eq!(input, selected);
            assert_eq!(input_format(&input), expected_format);
            let request: ProgrammerRequest = serde_json::from_value(
                json!({"operation":"verify","chip":"TEST@DIP8","file":selected}),
            )
            .unwrap();
            let args = arguments(&request).unwrap();
            assert_eq!(args[2], input.as_os_str());
            assert_eq!(args[3], "--format");
            assert_eq!(args[4], expected_format);
        }
        let broken = directory.path().join("broken.bin");
        symlink(directory.path().join("missing"), &broken).unwrap();
        assert!(input_file(broken.to_str()).is_err());
        let folder = directory.path().join("folder.bin");
        symlink(directory.path(), &folder).unwrap();
        assert!(input_file(folder.to_str()).is_err());
    }
}
