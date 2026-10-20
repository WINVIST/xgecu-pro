// SPDX-FileCopyrightText: 2026 John Fabienke
// SPDX-License-Identifier: MIT

//! Unpacking XGecu's installer with whatever RAR-capable tool the system
//! already has.
//!
//! The vendor ships the chip database as `xgpro_T76_V*.rar` → a WinRAR SFX
//! executable → `InfoICT76.dll` + `algoT76/*.alg`, so getting at it needs a
//! RAR5 decoder. Decoding is delegated to an external extractor rather than
//! linking a decoder into the Rust database parser. System packages provide
//! the extractor on macOS, Windows and Debian; the desktop AppImage packages
//! bsdtar and its supporting libraries with their license notices.
//!
//! Tools are probed in order of how well they are known to work here:
//!
//! | Tool | Notes |
//! |---|---|
//! | `bsdtar` | libarchive's RAR5 reader; **ships with macOS**, `libarchive-tools` on Debian |
//! | Windows `tar.exe` | Windows 11's system libarchive build |
//! | `unar` | The Unarchiver / XADMaster |
//! | `unrar` | RARLAB's own extractor |
//!
//! **`7z` is deliberately excluded.** Both p7zip and the official `7zz` list
//! the archive happily and then write **zero-byte files** — a silent corruption
//! that looks like success. Verified on this vendor archive; using it would be
//! worse than reporting no extractor at all.

use std::io::Read as _;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use minipro_core::error::{Error, Result};

/// Leading bytes that mark a file as a vendor archive we can unpack.
///
/// Content beats extension here: XGecu's own naming has varied (`.rar` today,
/// a bare SFX `.exe` inside it), users rename downloads, and a browser may
/// serve the installer as `.bin`. Sniffing also rejects the opposite mistake —
/// an unrelated `.exe` — before spawning an extractor on it.
const ARCHIVE_MAGIC: &[(&[u8], &str)] = &[
    (&[0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00], "RAR5"),
    (&[0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00], "RAR4"),
    // WinRAR SFX: a PE executable with an archive appended.
    (&[0x4d, 0x5a], "PE/SFX"),
];

/// Does `path` look like a vendor archive, judged by its first bytes?
pub fn is_vendor_archive(path: &Path) -> bool {
    archive_kind(path).is_some()
}

/// The archive flavour of `path`, or `None` if it is not one (or unreadable).
pub fn archive_kind(path: &Path) -> Option<&'static str> {
    if !path.is_file() {
        return None;
    }
    let mut head = [0u8; 8];
    let n = std::fs::File::open(path)
        .and_then(|mut f| f.read(&mut head))
        .ok()?;
    let head = head.get(..n)?;
    ARCHIVE_MAGIC
        .iter()
        .find(|(magic, _)| head.starts_with(magic))
        .map(|(_, name)| *name)
}

/// A RAR-capable extractor found on the system.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Extractor {
    /// `bsdtar -xf <archive>` (libarchive).
    BsdTar,
    /// The libarchive `tar.exe` shipped in the Windows system directory.
    WindowsTar,
    /// `unar -q -f -o <dir> <archive>`.
    Unar,
    /// `unrar x -y <archive> <dir>/`.
    Unrar,
}

impl Extractor {
    pub fn program(self) -> &'static str {
        match self {
            Extractor::BsdTar => "bsdtar",
            Extractor::WindowsTar => "tar.exe",
            Extractor::Unar => "unar",
            Extractor::Unrar => "unrar",
        }
    }

    /// Can this tool extract a named subset instead of the whole archive?
    /// `unar` has no member selection, so it always unpacks everything and
    /// relies on [`prune`] afterwards.
    fn supports_members(self) -> bool {
        matches!(
            self,
            Extractor::BsdTar | Extractor::WindowsTar | Extractor::Unrar
        )
    }

    fn executable(self) -> PathBuf {
        #[cfg(target_os = "linux")]
        if self == Extractor::BsdTar {
            if let Some(appdir) = std::env::var_os("APPDIR").filter(|p| !p.is_empty()) {
                let bundled = PathBuf::from(appdir).join("usr/bin/bsdtar");
                if bundled.is_file() {
                    return bundled;
                }
            }
        }
        if self == Extractor::WindowsTar {
            // Do not accidentally select GNU tar or a tar.exe in the cwd.
            return std::env::var_os("SystemRoot")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(r"C:\Windows"))
                .join("System32")
                .join("tar.exe");
        }
        PathBuf::from(self.program())
    }

    fn command(self) -> Command {
        let mut command = Command::new(self.executable());
        hide_console(&mut command);
        #[cfg(target_os = "linux")]
        if self == Extractor::BsdTar {
            if let Some(appdir) = std::env::var_os("APPDIR").filter(|p| !p.is_empty()) {
                let libraries = PathBuf::from(appdir).join("usr/lib/xgecu-extract");
                if libraries.is_dir() {
                    let mut paths = vec![libraries];
                    if let Some(previous) = std::env::var_os("LD_LIBRARY_PATH") {
                        paths.extend(std::env::split_paths(&previous));
                    }
                    if let Ok(paths) = std::env::join_paths(paths) {
                        command.env("LD_LIBRARY_PATH", paths);
                    }
                }
            }
        }
        command
    }

    /// Extract `archive` into `dest` (which must exist), optionally limited to
    /// `members`. Selecting members matters: the installer carries ~150 MB of
    /// drivers, language packs and GUI we never read.
    fn run(self, archive: &Path, dest: &Path, members: &[&str]) -> Result<()> {
        let mut cmd = self.command();
        let members = if self.supports_members() {
            members
        } else {
            &[][..]
        };
        match self {
            // bsdtar has no output-directory flag; it extracts into the cwd.
            Extractor::BsdTar => {
                cmd.arg("-xf").arg(archive).args(members).current_dir(dest);
            }
            Extractor::WindowsTar => {
                // Windows' libarchive build reads argv through the ANSI code
                // page. Open the Unicode archive path ourselves and use the
                // wide-character process cwd for its destination. Inherit a
                // seekable file handle, not a pipe: RAR/SFX readers may seek.
                let input = std::fs::File::open(archive)?;
                cmd.args(["-xf", "-"])
                    .args(members)
                    .stdin(Stdio::from(input))
                    .current_dir(dest);
            }
            Extractor::Unar => {
                cmd.args(["-q", "-f", "-o"]).arg(dest).arg(archive);
            }
            Extractor::Unrar => {
                cmd.args(["x", "-y"]).arg(archive).args(members).arg(dest);
            }
        }
        // Extractors process untrusted archives. Keep both their runtime and
        // output bounded, including tools that ignore member selection.
        let mut child = cmd
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| Error::Format(format!("could not run {}: {e}", self.program())))?;
        let started = Instant::now();
        loop {
            if let Some(status) = child.try_wait()? {
                if status.success() {
                    if !extracted_tree_exceeds_limit(dest)? {
                        return Ok(());
                    }
                    return Err(Error::Format(format!(
                        "{} extraction exceeded the 1 GiB/20,000-file limit",
                        self.program()
                    )));
                }
                return Err(Error::Format(format!(
                    "{} failed on {} (exit status {status})",
                    self.program(),
                    archive.display()
                )));
            }
            let over_limit = match extracted_tree_exceeds_limit(dest) {
                Ok(value) => value,
                Err(e) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(e);
                }
            };
            if started.elapsed() > Duration::from_secs(300) || over_limit {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::Format(format!(
                    "{} extraction exceeded the five-minute or 1 GiB/20,000-file limit",
                    self.program()
                )));
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}

fn extracted_tree_exceeds_limit(root: &Path) -> Result<bool> {
    const MAX_BYTES: u64 = 1 << 30;
    const MAX_ENTRIES: u64 = 20_000;
    let mut bytes = 0u64;
    let mut entries = 0u64;
    checked_directory(root, root)?;
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        checked_directory(root, &dir)?;
        for item in std::fs::read_dir(dir)? {
            let item = item?;
            entries += 1;
            if entries > MAX_ENTRIES {
                return Ok(true);
            }
            let meta = std::fs::symlink_metadata(item.path())?;
            if is_link(&meta) || (!meta.is_dir() && !meta.is_file()) {
                return Err(unsafe_extraction_entry());
            }
            checked_containment(root, &item.path())?;
            if meta.is_dir() {
                pending.push(item.path());
            } else if meta.is_file() {
                bytes = bytes.saturating_add(meta.len());
                if bytes > MAX_BYTES {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

fn unsafe_extraction_entry() -> Error {
    Error::Format("the extracted database must contain only real directories and regular files inside its extraction directory; links and special files are not allowed".into())
}

fn is_link(metadata: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        // Includes junctions and other reparse points, not only file symlinks.
        metadata.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    metadata.file_type().is_symlink()
}

fn checked_containment(root: &Path, path: &Path) -> Result<()> {
    let canonical_root = std::fs::canonicalize(root)?;
    let canonical_path = std::fs::canonicalize(path)?;
    if !canonical_path.starts_with(&canonical_root) {
        return Err(unsafe_extraction_entry());
    }
    Ok(())
}

fn checked_directory(root: &Path, directory: &Path) -> Result<()> {
    for path in [root, directory] {
        let metadata = std::fs::symlink_metadata(path)?;
        if is_link(&metadata) || !metadata.is_dir() {
            return Err(unsafe_extraction_entry());
        }
    }
    checked_containment(root, directory)
}

/// Validate before searching or pruning, even when an extractor has already
/// exited successfully. No candidate finder may follow a link out of storage.
fn validate_extracted_tree(root: &Path) -> Result<()> {
    if extracted_tree_exceeds_limit(root)? {
        return Err(Error::Format(
            "extracted database exceeds the 1 GiB/20,000-file limit".into(),
        ));
    }
    Ok(())
}

/// The first usable extractor on this system, if any.
pub fn find() -> Option<Extractor> {
    candidates(cfg!(windows)).into_iter().find(|e| probe(*e))
}

fn candidates(windows: bool) -> Vec<Extractor> {
    let mut tools = vec![Extractor::BsdTar, Extractor::Unar, Extractor::Unrar];
    if windows {
        // The desktop app supplies a UTF-8-capable bsdtar. System tar remains
        // a fallback, but some builds reject non-ANSI names in vendor SFXs.
        tools.insert(1, Extractor::WindowsTar);
    }
    tools
}

fn hide_console(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    #[cfg(not(windows))]
    let _ = command;
}

/// Is `program` present and runnable? Probed by execution rather than a PATH
/// search, so a shadowed or non-executable entry does not count as available.
fn probe(tool: Extractor) -> bool {
    // `unar` has no --version; every candidate accepts being run bare and
    // exits, which is enough to prove it exists and starts.
    let mut command = tool.command();
    command
        .arg("--version")
        .output()
        .map(|o| {
            if tool == Extractor::WindowsTar {
                let version = String::from_utf8_lossy(&o.stdout).to_ascii_lowercase();
                return o.status.success()
                    && (version.contains("bsdtar") || version.contains("libarchive"));
            }
            o.status.success() || !o.stdout.is_empty() || !o.stderr.is_empty()
        })
        .unwrap_or(false)
}

/// Advice shown when no extractor is installed. Names the exact packages,
/// because "install a RAR tool" is not actionable on an unfamiliar system.
pub fn install_hint() -> String {
    let install = if cfg!(target_os = "macos") {
        "  brew install unar          (bsdtar normally ships with macOS already)"
    } else if cfg!(target_os = "windows") {
        "  Windows 11 normally includes tar.exe (libarchive) in System32.\n  \
         Restore the system tar.exe or install RARLab.WinRAR with winget."
    } else {
        "  apt install libarchive-tools   (bsdtar)\n  \
         dnf install bsdtar             — or `apt install unar`"
    };
    format!(
        "no RAR-capable extractor found. The chip database ships inside XGecu's\n\
         installer archive, which needs one of: bsdtar, Windows tar.exe, unar, unrar.\n\n\
         Install one:\n{install}\n\n\
         Note: 7-Zip cannot be used — it lists the archive but writes zero-byte\n\
         files, which looks like success.\n\n\
         Or skip the download entirely: extract the archive on any machine and\n\
         point at the result:\n  \
         minipro --db /path/to/Xgpro_T76 …"
    )
}

/// Unpack the vendor archive into `dest`, returning the directory that actually
/// holds `InfoICT76.dll`.
///
/// The archive nests: the outer `.rar` contains a WinRAR SFX `.exe`, which
/// contains the payload — so this extracts, looks for the DLL, and if it only
/// found another executable, extracts that too.
pub fn unpack_vendor_archive(archive: &Path, dest: &Path) -> Result<PathBuf> {
    let tool = find().ok_or_else(|| Error::Format(install_hint()))?;
    std::fs::create_dir_all(dest)?;
    // A caller's pre-existing destination must not redirect extraction either.
    validate_extracted_tree(dest)?;
    // The outer archive holds only the installer, so nothing to select there.
    tool.run(archive, dest, &[])?;

    if let Some(dir) = find_database_dir(dest)? {
        prune(dest, &dir)?;
        return Ok(dir);
    }
    // Outer layer only yielded the installer; unpack that as well.
    let inner = find_installer_exe(dest)?.ok_or_else(|| {
        Error::Format(format!(
            "{} unpacked {} but produced neither InfoICT76.dll nor an installer .exe",
            tool.program(),
            archive.display()
        ))
    })?;
    // Inner layer: take only the database, not the whole vendor install.
    tool.run(&inner, dest, &["InfoICT76.dll", "algoT76"])?;
    let _ = std::fs::remove_file(&inner); // the 65 MB installer has served its purpose
    let dir = find_database_dir(dest)?.ok_or_else(|| {
        Error::Format(format!(
            "unpacked {} but found no InfoICT76.dll — if you used 7-Zip earlier, \
             its zero-byte output may be cached; clear {} and retry",
            archive.display(),
            dest.display()
        ))
    })?;
    prune(dest, &dir)?;
    Ok(dir)
}

/// Files the database actually needs. The vendor installer also carries
/// drivers, language packs and the GUI — ~150 MB we would otherwise keep
/// forever in a cache directory.
const KEEP: &[&str] = &[
    "InfoICT76.dll",
    "algoT76",
    "algorithm.xml",
    "infoic.xml",
    "logicic.xml",
];

/// Drop unused files only after checking the entire extraction tree and the
/// selected directory. Ordinary cleanup failures remain best-effort.
fn prune(root: &Path, dir: &Path) -> Result<()> {
    validate_extracted_tree(root)?;
    checked_directory(root, dir)?;
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Ok(());
    };
    for entry in entries.filter_map(|e| e.ok()) {
        let keep = entry
            .file_name()
            .to_str()
            .is_some_and(|n| KEEP.iter().any(|k| k.eq_ignore_ascii_case(n)));
        if keep {
            continue;
        }
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path)?;
        if is_link(&metadata) || (!metadata.is_file() && !metadata.is_dir()) {
            return Err(unsafe_extraction_entry());
        }
        checked_containment(root, &path)?;
        let _ = if metadata.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
    }
    Ok(())
}

/// Directory containing a *non-empty* `InfoICT76.dll`, searched one level deep.
/// The size check is what catches 7-Zip's zero-byte output.
fn find_database_dir(root: &Path) -> Result<Option<PathBuf>> {
    validate_extracted_tree(root)?;
    let usable = |dir: &Path| {
        std::fs::symlink_metadata(dir.join("InfoICT76.dll"))
            .map(|m| !is_link(&m) && m.is_file() && m.len() > 0)
            .unwrap_or(false)
    };
    if usable(root) {
        return Ok(Some(root.to_path_buf()));
    }
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        let metadata = std::fs::symlink_metadata(&path)?;
        if is_link(&metadata) {
            return Err(unsafe_extraction_entry());
        }
        if metadata.is_dir() {
            checked_directory(root, &path)?;
            if usable(&path) {
                return Ok(Some(path));
            }
        }
    }
    Ok(None)
}

/// The nested installer executable, searched one level deep.
fn find_installer_exe(root: &Path) -> Result<Option<PathBuf>> {
    validate_extracted_tree(root)?;
    fn exe(p: &Path) -> bool {
        p.extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| e.eq_ignore_ascii_case("exe"))
    }
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        checked_directory(root, &dir)?;
        for entry in std::fs::read_dir(&dir)? {
            let entry = entry?;
            let p = entry.path();
            let metadata = std::fs::symlink_metadata(&p)?;
            if is_link(&metadata) || (!metadata.is_file() && !metadata.is_dir()) {
                return Err(unsafe_extraction_entry());
            }
            checked_containment(root, &p)?;
            if metadata.is_file() && exe(&p) {
                return Ok(Some(p));
            }
            if metadata.is_dir() && dir == root {
                stack.push(p);
            }
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_prefers_utf8_bsdtar_then_system_tar_before_optional_tools() {
        assert_eq!(
            candidates(true),
            vec![
                Extractor::BsdTar,
                Extractor::WindowsTar,
                Extractor::Unar,
                Extractor::Unrar
            ]
        );
        assert!(!candidates(false).contains(&Extractor::WindowsTar));
        assert!(Extractor::WindowsTar.supports_members());
        assert_eq!(Extractor::WindowsTar.program(), "tar.exe");
        let path = Extractor::WindowsTar.executable();
        assert_eq!(path.file_name().and_then(|s| s.to_str()), Some("tar.exe"));
        assert_eq!(
            path.parent()
                .and_then(Path::file_name)
                .and_then(|s| s.to_str()),
            Some("System32")
        );
    }

    #[cfg(windows)]
    #[test]
    fn system_windows_tar_extracts_selected_members_with_unicode_paths() {
        let tool = Extractor::WindowsTar;
        assert!(
            probe(tool),
            "supported Windows installations must provide system libarchive tar.exe"
        );
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("source with spaces База");
        let destination = directory.path().join("destination with spaces База");
        std::fs::create_dir_all(source.join("algoT76")).unwrap();
        std::fs::create_dir_all(&destination).unwrap();
        std::fs::write(source.join("InfoICT76.dll"), b"test catalog").unwrap();
        std::fs::write(source.join("algoT76/test.alg"), b"test algorithm").unwrap();
        std::fs::write(source.join("unneeded.txt"), b"not selected").unwrap();
        let archive = directory.path().join("archive with spaces База.tar");
        let status = tool
            .command()
            .args(["-cf", "-"])
            .stdout(std::fs::File::create(&archive).unwrap())
            .current_dir(&source)
            .args(["InfoICT76.dll", "algoT76", "unneeded.txt"])
            .status()
            .unwrap();
        assert!(status.success());
        tool.run(&archive, &destination, &["InfoICT76.dll", "algoT76"])
            .unwrap();
        assert_eq!(
            std::fs::read(destination.join("InfoICT76.dll")).unwrap(),
            b"test catalog"
        );
        assert_eq!(
            std::fs::read(destination.join("algoT76/test.alg")).unwrap(),
            b"test algorithm"
        );
        assert!(!destination.join("unneeded.txt").exists());
    }

    #[test]
    fn archive_detection_reads_content_not_extension() {
        let dir = tempfile::tempdir().unwrap();
        // Correct content, misleading name — must still be recognised.
        let odd = dir.path().join("download.bin");
        std::fs::write(&odd, b"Rar!\x1a\x07\x01\x00rest").unwrap();
        assert_eq!(archive_kind(&odd), Some("RAR5"));

        // Right extension, wrong content — must be rejected before we spawn
        // an extractor on it.
        let fake = dir.path().join("installer.exe");
        std::fs::write(&fake, b"#!/bin/sh\necho not an archive\n").unwrap();
        assert_eq!(archive_kind(&fake), None);

        // A real SFX is a PE image.
        let sfx = dir.path().join("setup.exe");
        std::fs::write(&sfx, b"MZ\x90\x00padding").unwrap();
        assert_eq!(archive_kind(&sfx), Some("PE/SFX"));
    }

    #[test]
    fn archive_detection_tolerates_tiny_and_missing_files() {
        let dir = tempfile::tempdir().unwrap();
        let tiny = dir.path().join("t");
        std::fs::write(&tiny, b"R").unwrap();
        assert_eq!(archive_kind(&tiny), None);
        assert_eq!(archive_kind(&dir.path().join("nope")), None);
        assert_eq!(
            archive_kind(dir.path()),
            None,
            "a directory is not an archive"
        );
    }

    #[test]
    fn install_hint_is_actionable() {
        let h = install_hint();
        assert!(h.contains("bsdtar"), "must name a tool: {h}");
        assert!(h.contains("--db"), "must offer the manual fallback: {h}");
        assert!(
            h.contains("7-Zip"),
            "must warn about the zero-byte trap: {h}"
        );
    }

    #[test]
    fn zero_byte_dll_is_not_accepted() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("InfoICT76.dll"), b"").unwrap();
        assert!(
            find_database_dir(dir.path()).unwrap().is_none(),
            "an empty DLL is 7-Zip's failure mode and must not count"
        );
    }

    #[test]
    fn nonempty_dll_is_found_one_level_deep() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("Xgpro_T76_V1321");
        std::fs::create_dir_all(&sub).unwrap();
        std::fs::write(sub.join("InfoICT76.dll"), b"x").unwrap();
        assert_eq!(
            find_database_dir(dir.path()).unwrap().as_deref(),
            Some(sub.as_path())
        );
    }

    #[test]
    fn extraction_tree_limit_counts_bytes_and_entries() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("small"), b"ok").unwrap();
        assert!(!extracted_tree_exceeds_limit(dir.path()).unwrap());
        let large = std::fs::File::create(dir.path().join("large")).unwrap();
        large.set_len((1u64 << 30) + 1).unwrap();
        assert!(extracted_tree_exceeds_limit(dir.path()).unwrap());
    }

    #[test]
    fn normal_nested_database_layout_can_be_found_and_pruned() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("Xgpro_T76_V1321");
        std::fs::create_dir_all(database.join("algoT76")).unwrap();
        std::fs::create_dir_all(database.join("vendor-gui")).unwrap();
        std::fs::write(database.join("InfoICT76.dll"), b"catalog").unwrap();
        std::fs::write(database.join("algoT76/test.alg"), b"algorithm").unwrap();
        std::fs::write(database.join("vendor-gui/unneeded.bin"), b"gui").unwrap();
        std::fs::write(database.join("unneeded.txt"), b"extra").unwrap();
        let found = find_database_dir(directory.path()).unwrap().unwrap();
        assert_eq!(found, database);
        prune(directory.path(), &found).unwrap();
        assert_eq!(
            std::fs::read(database.join("InfoICT76.dll")).unwrap(),
            b"catalog"
        );
        assert_eq!(
            std::fs::read(database.join("algoT76/test.alg")).unwrap(),
            b"algorithm"
        );
        assert!(!database.join("unneeded.txt").exists());
        assert!(!database.join("vendor-gui").exists());
        validate_extracted_tree(directory.path()).unwrap();
    }

    #[test]
    fn normal_nested_installer_layout_is_found_without_descending_further() {
        let directory = tempfile::tempdir().unwrap();
        let installer = directory.path().join("wrapper/installer.EXE");
        std::fs::create_dir_all(installer.parent().unwrap()).unwrap();
        std::fs::write(&installer, b"MZinstaller").unwrap();
        assert_eq!(
            find_installer_exe(directory.path()).unwrap(),
            Some(installer)
        );
    }

    #[test]
    fn prune_rejects_an_outside_candidate_before_touching_its_contents() {
        let extraction = tempfile::tempdir().unwrap();
        let external = tempfile::tempdir().unwrap();
        std::fs::write(extraction.path().join("InfoICT76.dll"), b"local catalog").unwrap();
        std::fs::write(external.path().join("InfoICT76.dll"), b"external catalog").unwrap();
        let marker = external.path().join("keep-my-notes.txt");
        std::fs::write(&marker, b"outside extraction storage").unwrap();
        assert!(prune(extraction.path(), external.path()).is_err());
        assert_eq!(
            std::fs::read(marker).unwrap(),
            b"outside extraction storage"
        );
    }

    #[cfg(unix)]
    #[test]
    fn malicious_extracted_directory_symlink_cannot_prune_external_files_or_change_modes() {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let extraction = tempfile::tempdir().unwrap();
        let external = tempfile::tempdir().unwrap();
        let database = external.path().join("InfoICT76.dll");
        let marker = external.path().join("keep-my-notes.txt");
        std::fs::write(&database, b"external catalog").unwrap();
        std::fs::write(&marker, b"outside extraction storage").unwrap();
        std::fs::set_permissions(&database, std::fs::Permissions::from_mode(0o600)).unwrap();
        std::fs::set_permissions(&marker, std::fs::Permissions::from_mode(0o640)).unwrap();
        let alias = extraction.path().join("Xgpro_T76_V1321");
        symlink(external.path(), &alias).unwrap();

        assert!(extracted_tree_exceeds_limit(extraction.path()).is_err());
        assert!(find_database_dir(extraction.path()).is_err());
        assert!(find_installer_exe(extraction.path()).is_err());
        assert!(prune(extraction.path(), &alias).is_err());
        // Even using the link itself as the apparent extraction root fails.
        assert!(find_database_dir(&alias).is_err());
        assert!(prune(&alias, &alias).is_err());

        assert_eq!(std::fs::read(&database).unwrap(), b"external catalog");
        assert_eq!(
            std::fs::read(&marker).unwrap(),
            b"outside extraction storage"
        );
        assert_eq!(
            std::fs::metadata(database).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            std::fs::metadata(marker).unwrap().permissions().mode() & 0o777,
            0o640
        );
    }

    #[cfg(unix)]
    #[test]
    fn extracted_database_file_links_and_special_files_are_rejected() {
        use std::os::unix::{fs::symlink, net::UnixListener};
        let extraction = tempfile::tempdir().unwrap();
        let external = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(external.path(), b"external catalog").unwrap();
        let link = extraction.path().join("InfoICT76.dll");
        symlink(external.path(), &link).unwrap();
        assert!(find_database_dir(extraction.path()).is_err());
        assert!(prune(extraction.path(), extraction.path()).is_err());
        assert_eq!(std::fs::read(external.path()).unwrap(), b"external catalog");
        std::fs::remove_file(link).unwrap();
        let _socket = UnixListener::bind(extraction.path().join("special.socket")).unwrap();
        assert!(extracted_tree_exceeds_limit(extraction.path()).is_err());
        assert!(find_database_dir(extraction.path()).is_err());
    }

    /// At least one extractor should exist in a normal dev environment; this is
    /// informational rather than a hard requirement.
    #[test]
    fn probe_reports_something_on_this_machine() {
        eprintln!("extractor found: {:?}", find());
    }
}
