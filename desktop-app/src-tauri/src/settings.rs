use crate::error::{BridgeError, Result};
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    io::{Read, Write},
    path::Path,
};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Theme {
    #[default]
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    #[serde(default)]
    pub database_path: String,
    #[serde(default)]
    pub favorites: Vec<String>,
    #[serde(default)]
    pub theme: Theme,
}

pub fn load(path: &Path) -> Result<Settings> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(Settings::default())
        }
        Err(error) => return Err(error.into()),
    };
    let mut bytes = Vec::new();
    file.take(4 * 1024 * 1024 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(BridgeError::new("settings", "Settings file is too large."));
    }
    serde_json::from_slice(&bytes)
        .map_err(|e| BridgeError::new("settings", format!("Could not read settings: {e}")))
}

pub fn save(path: &Path, mut settings: Settings) -> Result<Settings> {
    if settings.database_path.len() > 32768
        || settings.favorites.len() > 10000
        || settings
            .favorites
            .iter()
            .any(|s| s.is_empty() || s.len() > 512 || s.chars().any(char::is_control))
    {
        return Err(BridgeError::new(
            "settings",
            "Invalid database path or favorites.",
        ));
    }
    settings.favorites.sort_by_key(|s| s.to_lowercase());
    settings.favorites.dedup();
    let parent = path
        .parent()
        .ok_or_else(|| BridgeError::new("settings", "Invalid settings directory."))?;
    std::fs::create_dir_all(parent)?;
    let bytes = serde_json::to_vec_pretty(&settings)
        .map_err(|e| BridgeError::new("settings", e.to_string()))?;
    if bytes.len() > 4 * 1024 * 1024 {
        return Err(BridgeError::new(
            "settings",
            "Settings exceed the 4 MiB size limit.",
        ));
    }
    let mut file = tempfile::NamedTempFile::new_in(parent)?;
    file.write_all(&bytes)?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|e| BridgeError::from(e.error))?;
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn settings_roundtrip_is_atomic_and_keeps_user_preferences() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        assert!(load(&path).unwrap().database_path.is_empty());
        let settings = Settings {
            database_path: "C:\\База\\chips".into(),
            favorites: vec!["Z".into(), "A".into(), "Z".into()],
            theme: Theme::Dark,
        };
        save(&path, settings).unwrap();
        assert_eq!(load(&path).unwrap().favorites, ["A", "Z"]);
        save(&path, Settings::default()).unwrap();
        assert!(load(&path).unwrap().favorites.is_empty());
    }
    #[test]
    fn broken_settings_are_reported_not_silently_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(&path, "broken").unwrap();
        assert_eq!(load(&path).unwrap_err().code, "settings");
        assert_eq!(std::fs::read_to_string(path).unwrap(), "broken");
    }
}
