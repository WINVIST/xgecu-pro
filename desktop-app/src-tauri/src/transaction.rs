//! Private immutable inputs survive from dry-run to exactly one commit. A
//! source edit or settings change cannot retarget an accepted confirmation.
use crate::{
    error::{BridgeError, Result},
    policy::{input_format, MAX_IMAGE_BYTES},
};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    ffi::OsString,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub struct PrivateDirectory(tempfile::TempDir);
impl PrivateDirectory {
    pub fn new(parent: &Path) -> Result<Self> {
        fs::create_dir_all(parent)?;
        let directory = tempfile::Builder::new()
            .prefix("transaction-")
            .tempdir_in(parent)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))?;
        }
        Ok(Self(directory))
    }
    pub fn path(&self) -> &Path {
        self.0.path()
    }
}
impl Drop for PrivateDirectory {
    fn drop(&mut self) {
        // Windows will not delete read-only files. Only touch descendants
        // created inside this owned directory, without following symlinks.
        #[cfg(windows)]
        {
            fn writable(path: &Path) {
                if let Ok(meta) = fs::symlink_metadata(path) {
                    if meta.file_type().is_symlink() {
                        return;
                    }
                    if meta.is_dir() {
                        if let Ok(items) = fs::read_dir(path) {
                            for item in items.flatten() {
                                writable(&item.path());
                            }
                        }
                    } else if meta.is_file() {
                        let mut mode = meta.permissions();
                        mode.set_readonly(false);
                        let _ = fs::set_permissions(path, mode);
                    }
                }
            }
            writable(self.0.path());
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreparedReply {
    pub token: String,
    pub chip: String,
    pub file: String,
    pub bytes: u64,
}

pub struct PreparedProgram {
    pub token: String,
    pub chip: String,
    pub image: PathBuf,
    pub database: PathBuf,
    pub format: &'static str,
    pub image_digest: String,
    pub database_digest: String,
    pub _directory: PrivateDirectory,
}

impl PreparedProgram {
    pub fn arguments(&self, dry_run: bool) -> Vec<OsString> {
        let mut args = vec![
            "write".into(),
            self.chip.clone().into(),
            self.image.as_os_str().into(),
            "--format".into(),
            self.format.into(),
        ];
        if dry_run {
            args.push("--dry-run".into());
        }
        args
    }
    pub fn validate(&self) -> Result<()> {
        if hash_file(&self.image)? != self.image_digest
            || tree_digest(&self.database)? != self.database_digest
        {
            return Err(BridgeError::new(
                "snapshot_changed",
                "The private firmware or database snapshot changed. Prepare the operation again.",
            ));
        }
        Ok(())
    }
}

pub fn snapshot_image(source: &Path, directory: &Path) -> Result<(PathBuf, u64, String)> {
    let format = input_format(source);
    let limit = if format == "raw" {
        MAX_IMAGE_BYTES
    } else {
        8 * 1024 * 1024 * 1024
    };
    let suffix = source
        .extension()
        .and_then(|s| s.to_str())
        .filter(|s| s.len() < 16 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'))
        .unwrap_or("image");
    let output = directory.join(format!("program.{suffix}"));
    let (bytes, digest) = copy_bounded(source, &output, limit)?;
    if bytes == 0 {
        return Err(BridgeError::new(
            "empty_image",
            "The programming image is empty.",
        ));
    }
    seal(&output)?;
    Ok((output, bytes, digest))
}

pub fn snapshot_database(source: &Path, directory: &Path) -> Result<PathBuf> {
    if source.is_file() {
        if !minipro_db::extract::is_vendor_archive(source) {
            return Err(BridgeError::new(
                "invalid_database",
                "Choose an extracted database directory or vendor RAR/SFX archive.",
            ));
        }
        let archive = directory.join("vendor.archive");
        copy_bounded(source, &archive, 96 * 1024 * 1024)?;
        let destination = directory.join("database");
        let extracted = minipro_db::extract::unpack_vendor_archive(&archive, &destination)
            .map_err(|e| BridgeError::new("database_extract", e.to_string()))?;
        fs::remove_file(archive)?;
        seal_tree(&extracted)?;
        // The limits and symlink checks are independently enforced after extraction.
        tree_digest(&extracted)?;
        return Ok(extracted);
    }
    if !source.is_dir() {
        return Err(BridgeError::new(
            "invalid_database",
            "The selected database directory does not exist.",
        ));
    }
    let destination = directory.join("database");
    fs::create_dir(&destination)?;
    let files = database_files(source)?;
    let mut total = 0u64;
    for path in files {
        let relative = path
            .strip_prefix(source)
            .map_err(|_| BridgeError::new("invalid_database", "Invalid database file path."))?;
        let target = destination.join(relative);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let remaining = (1u64 << 30).saturating_sub(total);
        let (bytes, _) = copy_bounded(&path, &target, remaining)?;
        total += bytes;
        seal(&target)?;
    }
    if !destination.join("InfoICT76.dll").is_file() && !destination.join("infoic.xml").is_file() {
        return Err(BridgeError::new(
            "invalid_database",
            "The directory contains no chip database.",
        ));
    }
    Ok(destination)
}

pub fn default_database() -> Result<PathBuf> {
    let cache = match std::env::var_os("XDG_CACHE_HOME").filter(|p| !p.is_empty()) {
        Some(path) => PathBuf::from(path).join("minipro"),
        None => directories::ProjectDirs::from("", "", "minipro")
            .map(|d| d.cache_dir().to_path_buf())
            .unwrap_or_else(|| std::env::temp_dir().join("minipro-cache")),
    };
    // This is the exact pinned directory used by the bundled minipro source.
    // A successful initial describe ensures that the verified source is ready.
    let path = cache.join("xgpro-pinned-v1321");
    if !path.join("InfoICT76.dll").is_file() {
        return Err(BridgeError::new(
            "database_missing",
            "The pinned chip database is not prepared. Browse the chip catalog first.",
        ));
    }
    Ok(path)
}

pub fn hash_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 64 * 1024];
    loop {
        let n = file.read(&mut bytes)?;
        if n == 0 {
            break;
        }
        hash.update(&bytes[..n]);
    }
    Ok(hash
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn copy_bounded(source: &Path, target: &Path, limit: u64) -> Result<(u64, String)> {
    let mut input = File::open(source)?;
    let metadata = input.metadata()?;
    if !metadata.is_file() {
        return Err(BridgeError::new(
            "invalid_file",
            "Only regular files can be copied.",
        ));
    }
    if metadata.len() > limit {
        return Err(BridgeError::new(
            "image_too_large",
            "The image or database exceeds its size limit.",
        ));
    }
    let mut options = OpenOptions::new();
    options.create_new(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut output = options.open(target)?;
    let mut hash = Sha256::new();
    let mut bytes = [0; 64 * 1024];
    let mut copied = 0u64;
    loop {
        let n = input.read(&mut bytes)?;
        if n == 0 {
            break;
        }
        if n as u64 > limit.saturating_sub(copied) {
            return Err(BridgeError::new(
                "image_too_large",
                "The image or database exceeds its size limit.",
            ));
        }
        output.write_all(&bytes[..n])?;
        hash.update(&bytes[..n]);
        copied += n as u64;
    }
    output.sync_all()?;
    Ok((
        copied,
        hash.finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect(),
    ))
}

fn seal(path: &Path) -> Result<()> {
    let mut permissions = fs::metadata(path)?.permissions();
    permissions.set_readonly(true);
    fs::set_permissions(path, permissions)?;
    Ok(())
}
fn seal_tree(root: &Path) -> Result<()> {
    for file in database_files(root)? {
        seal(&file)?;
    }
    Ok(())
}

fn database_files(root: &Path) -> Result<Vec<PathBuf>> {
    let root_metadata = fs::symlink_metadata(root)?;
    if !root_metadata.is_dir() || root_metadata.file_type().is_symlink() {
        return Err(BridgeError::new(
            "invalid_database",
            "Database snapshots require a real directory root, without symbolic links.",
        ));
    }
    let mut files = vec![];
    let mut pending = vec![root.to_path_buf()];
    let mut entries = 0;
    let mut size = 0u64;
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let meta = fs::symlink_metadata(entry.path())?;
            entries += 1;
            if entries > 20000 {
                return Err(BridgeError::new(
                    "database_too_large",
                    "Database exceeds 20,000 files.",
                ));
            }
            if meta.file_type().is_symlink() {
                return Err(BridgeError::new(
                    "invalid_database",
                    "Database snapshots cannot contain symbolic links.",
                ));
            }
            if meta.is_dir() {
                pending.push(entry.path());
            } else if meta.is_file() {
                size = size.saturating_add(meta.len());
                files.push(entry.path());
            } else {
                return Err(BridgeError::new(
                    "invalid_database",
                    "Database contains a non-regular file.",
                ));
            }
            if size > 1u64 << 30 {
                return Err(BridgeError::new(
                    "database_too_large",
                    "Database exceeds 1 GiB.",
                ));
            }
        }
    }
    files.sort();
    Ok(files)
}

pub fn tree_digest(root: &Path) -> Result<String> {
    let mut digest = Sha256::new();
    for path in database_files(root)? {
        let relative = path
            .strip_prefix(root)
            .map_err(|_| BridgeError::new("invalid_database", "Invalid database path."))?;
        let name = relative.as_os_str().as_encoded_bytes();
        digest.update((name.len() as u64).to_le_bytes());
        digest.update(name);
        digest.update(hash_file(&path)?.as_bytes());
    }
    Ok(digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_change_after_preflight_cannot_change_private_program_image() {
        let parent = tempfile::tempdir().unwrap();
        let directory = PrivateDirectory::new(parent.path()).unwrap();
        let source = parent.path().join("прошивка.bin");
        fs::write(&source, b"original firmware").unwrap();
        let (image, bytes, digest) = snapshot_image(&source, directory.path()).unwrap();
        fs::write(&source, b"different firmware").unwrap();
        assert_eq!(bytes, 17);
        assert_eq!(fs::read(&image).unwrap(), b"original firmware");
        assert_eq!(hash_file(&image).unwrap(), digest);
    }
    #[test]
    fn private_database_is_frozen_and_digest_catches_tamper() {
        let parent = tempfile::tempdir().unwrap();
        let source = parent.path().join("db");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("InfoICT76.dll"), b"catalog").unwrap();
        let directory = PrivateDirectory::new(parent.path()).unwrap();
        let snapshot = snapshot_database(&source, directory.path()).unwrap();
        let digest = tree_digest(&snapshot).unwrap();
        fs::write(source.join("InfoICT76.dll"), b"new catalog").unwrap();
        assert_eq!(tree_digest(&snapshot).unwrap(), digest);
        fs::write(snapshot.join("newfile"), b"tamper").unwrap();
        assert_ne!(tree_digest(&snapshot).unwrap(), digest);
    }
    #[test]
    fn snapshot_copy_limits_are_checked_before_excess_bytes_are_written() {
        let parent = tempfile::tempdir().unwrap();
        let source = parent.path().join("source");
        fs::write(&source, b"12345").unwrap();
        assert_eq!(
            copy_bounded(&source, &parent.path().join("out"), 4)
                .unwrap_err()
                .code,
            "image_too_large"
        );
        assert!(!parent.path().join("out").exists());
    }

    #[test]
    fn over_limit_raw_image_is_rejected_before_copying_a_large_sparse_file() {
        let parent = tempfile::tempdir().unwrap();
        let source = parent.path().join("large.bin");
        File::create(&source)
            .unwrap()
            .set_len(MAX_IMAGE_BYTES + 1)
            .unwrap();
        let private = PrivateDirectory::new(parent.path()).unwrap();
        assert_eq!(
            snapshot_image(&source, private.path()).unwrap_err().code,
            "image_too_large"
        );
        assert_eq!(fs::read_dir(private.path()).unwrap().count(), 0);
    }
    #[test]
    fn prepared_transaction_rechecks_snapshot_and_keeps_locked_arguments() {
        let parent = tempfile::tempdir().unwrap();
        let directory = PrivateDirectory::new(parent.path()).unwrap();
        let source = parent.path().join("source.bin");
        fs::write(&source, b"original firmware").unwrap();
        let (image, _, image_digest) = snapshot_image(&source, directory.path()).unwrap();
        let original_db = parent.path().join("source-db");
        fs::create_dir(&original_db).unwrap();
        fs::write(original_db.join("InfoICT76.dll"), b"catalog").unwrap();
        let database = snapshot_database(&original_db, directory.path()).unwrap();
        let database_digest = tree_digest(&database).unwrap();
        let prepared = PreparedProgram {
            token: "token".into(),
            chip: "LOCKED@DIP8".into(),
            image: image.clone(),
            database: database.clone(),
            format: "raw",
            image_digest,
            database_digest,
            _directory: directory,
        };
        prepared.validate().unwrap();
        fs::write(source, b"replacement firmware").unwrap();
        fs::write(original_db.join("InfoICT76.dll"), b"replacement catalog").unwrap();
        prepared.validate().unwrap();
        assert_eq!(prepared.arguments(true)[1], "LOCKED@DIP8");
        assert_eq!(prepared.arguments(true)[2], image.as_os_str());
        assert_eq!(prepared.arguments(true).last().unwrap(), "--dry-run");
        assert_ne!(prepared.arguments(false).last().unwrap(), "--dry-run");
        fs::write(database.join("unexpected"), b"tamper").unwrap();
        assert_eq!(prepared.validate().unwrap_err().code, "snapshot_changed");
    }
    #[test]
    fn private_snapshot_keeps_explicit_text_format_extensions() {
        let parent = tempfile::tempdir().unwrap();
        let directory = PrivateDirectory::new(parent.path()).unwrap();
        let source = parent.path().join("dump.s-record");
        fs::write(&source, b"malformed S-record").unwrap();
        let (path, _, _) = snapshot_image(&source, directory.path()).unwrap();
        assert_eq!(path.extension().and_then(|s| s.to_str()), Some("s-record"));
        assert_eq!(input_format(&path), "auto");
    }
    #[cfg(unix)]
    #[test]
    fn programming_snapshots_preserve_selected_symlink_format_in_both_directions() {
        use std::os::unix::fs::symlink;
        let parent = tempfile::tempdir().unwrap();
        let bytes = b":03000000010203F7\n:00000001FF\n";
        for (selected_name, target_name, expected_format) in [
            ("firmware.bin", "payload.hex", "raw"),
            ("firmware.hex", "payload.bin", "auto"),
        ] {
            let target = parent.path().join(target_name);
            fs::write(&target, bytes).unwrap();
            let selected = parent.path().join(selected_name);
            symlink(target, &selected).unwrap();
            let source = crate::policy::input_file(selected.to_str()).unwrap();
            let format = input_format(&source);
            let directory = PrivateDirectory::new(parent.path()).unwrap();
            let (snapshot, _, image_digest) = snapshot_image(&source, directory.path()).unwrap();
            assert_eq!(snapshot.extension(), selected.extension());
            assert_eq!(fs::read(&snapshot).unwrap(), bytes);
            assert_eq!(format, expected_format);
            let program = PreparedProgram {
                token: "token".into(),
                chip: "TEST@DIP8".into(),
                image: snapshot,
                database: directory.path().join("database"),
                format,
                image_digest,
                database_digest: String::new(),
                _directory: directory,
            };
            let args = program.arguments(true);
            assert_eq!(args[3], "--format");
            assert_eq!(args[4], expected_format);
        }
    }
    #[cfg(unix)]
    #[test]
    fn database_root_symlink_is_rejected_without_sealing_external_files() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let parent = tempfile::tempdir().unwrap();
        let external = parent.path().join("external");
        fs::create_dir(&external).unwrap();
        let marker = external.join("InfoICT76.dll");
        fs::write(&marker, b"external marker").unwrap();
        fs::set_permissions(&marker, fs::Permissions::from_mode(0o640)).unwrap();
        let alias = parent.path().join("database-link");
        symlink(&external, &alias).unwrap();
        assert_eq!(database_files(&alias).unwrap_err().code, "invalid_database");
        assert_eq!(seal_tree(&alias).unwrap_err().code, "invalid_database");
        assert_eq!(tree_digest(&alias).unwrap_err().code, "invalid_database");
        assert_eq!(fs::read(&marker).unwrap(), b"external marker");
        assert_eq!(
            fs::metadata(marker).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }
}
