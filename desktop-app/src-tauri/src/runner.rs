//! The bundled helper is the sole USB entry point. Never execute a shell or
//! accept executable paths/arguments from the webview.
use crate::error::{BridgeError, Result};
use serde_json::Value;
use std::{
    ffi::OsString,
    io::{BufRead, BufReader, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
use tauri::{AppHandle, Manager};

const MAX_STDOUT: usize = 64 * 1024 * 1024;
const MAX_EVENT: usize = 64 * 1024;

#[derive(Clone)]
pub struct Runner {
    executable: PathBuf,
    extractor_dir: Option<PathBuf>,
}

impl Runner {
    pub fn resolve(app: &AppHandle) -> Result<Self> {
        let name = if cfg!(windows) {
            "minipro.exe"
        } else {
            "minipro"
        };
        let exe = std::env::current_exe()?;
        let parent = exe.parent().ok_or_else(|| {
            BridgeError::new(
                "helper_missing",
                "Could not locate the application directory.",
            )
        })?;
        let resource = app
            .path()
            .resource_dir()
            .map_err(|e| BridgeError::new("helper_missing", e.to_string()))?;
        let candidates = vec![
            parent.join(name),
            resource.join(name),
            resource.join("binaries").join(name),
        ];
        // A debug-only override supports developer builds and integration tests.
        // Packaged production builds never trust this environment variable.
        #[cfg(debug_assertions)]
        let candidates = {
            let mut candidates = candidates;
            if let Some(path) = std::env::var_os("XGECU_DEV_HELPER") {
                candidates.insert(0, PathBuf::from(path));
            }
            let target = if cfg!(windows) {
                "x86_64-pc-windows-msvc.exe"
            } else {
                "x86_64-unknown-linux-gnu"
            };
            candidates.push(
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("binaries")
                    .join(format!("minipro-{target}")),
            );
            candidates
        };
        let executable = candidates
            .into_iter()
            .find(|p| p.is_file())
            .ok_or_else(|| {
                BridgeError::new(
                    "helper_missing",
                    "The bundled minipro executable is missing.",
                )
                .hint("Reinstall XGecu Pro from a complete release package.")
            })?;
        let bundled_tools = [resource.join("tools"), resource.join("resources/tools")]
            .into_iter()
            .find(|path| path.is_dir());
        Ok(Self {
            executable,
            extractor_dir: bundled_tools,
        })
    }

    pub fn run(
        &self,
        args: &[OsString],
        database: Option<&Path>,
        mut event: impl FnMut(Value) + Send,
    ) -> Result<Value> {
        if args
            .first()
            .and_then(|arg| arg.to_str())
            .is_some_and(|command| {
                matches!(
                    command,
                    "info"
                        | "usb-diagnose"
                        | "autodetect"
                        | "check"
                        | "read"
                        | "verify"
                        | "blank"
                        | "erase"
                        | "write"
                )
            })
        {
            crate::driver::precheck()?;
        }
        let mut command = self.command(args, database);
        let mut child = command.spawn().map_err(|e| {
            BridgeError::new(
                "helper_start",
                format!("Could not start the bundled minipro: {e}"),
            )
        })?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| BridgeError::new("helper_pipe", "Could not read minipro output."))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| BridgeError::new("helper_pipe", "Could not read minipro progress."))?;
        // Drain both pipes concurrently: a full event pipe must never deadlock a
        // large catalog or a hardware operation. Even malformed output is drained.
        let (output, events, status) = std::thread::scope(|scope| {
            let output = scope.spawn(move || read_bounded(stdout, MAX_STDOUT));
            let events = scope.spawn(move || decode_events(stderr, &mut event));
            let status = child.wait();
            let output = output.join().map_err(|_| {
                BridgeError::new("helper_output", "The minipro output reader failed.")
            });
            let events = events.join().map_err(|_| {
                BridgeError::new("helper_output", "The minipro progress reader failed.")
            });
            (output, events, status)
        });
        let output = output??;
        events??;
        decode_result(&output, status?.success())
    }

    fn command(&self, args: &[OsString], database: Option<&Path>) -> Command {
        let mut command = Command::new(&self.executable);
        command.arg("--json");
        if let Some(path) = database {
            command.arg("--db").arg(path);
        }
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for name in [
            "MINIPRO_VENDOR_URL",
            "MINIPRO_DB_URL",
            "MINIPRO_DB_DIR",
            "MINIPRO_KEEP_BITSTREAM",
        ] {
            command.env_remove(name);
        }
        command
            .env("MINIPRO_REQUIRE_MODEL", "T76")
            .env("MINIPRO_REQUIRE_CHIP_ID", "1")
            .env("MINIPRO_TRUST_PINNED_DB_ONLY", "1");
        // Packages can ship bsdtar and its license alongside the helper. The
        // extractor directory only comes from the installed resource bundle.
        if let Some(dir) = &self.extractor_dir {
            let mut paths = vec![dir.clone()];
            if let Some(path) = std::env::var_os("PATH") {
                paths.extend(std::env::split_paths(&path));
            }
            if let Ok(path) = std::env::join_paths(paths) {
                command.env("PATH", path);
            }
        }
        #[cfg(target_os = "linux")]
        if let Some(appdir) = std::env::var_os("APPDIR")
            .filter(|p| !p.is_empty())
            .map(PathBuf::from)
        {
            let bins = appdir.join("usr/bin");
            let libraries = appdir.join("usr/lib/xgecu-extract");
            if bins.join("bsdtar").is_file() && libraries.is_dir() {
                for (name, first) in [("PATH", bins), ("LD_LIBRARY_PATH", libraries)] {
                    let mut paths = vec![first];
                    if let Some(previous) = std::env::var_os(name) {
                        paths.extend(std::env::split_paths(&previous));
                    }
                    if let Ok(paths) = std::env::join_paths(paths) {
                        command.env(name, paths);
                    }
                }
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        command
    }
}

fn read_bounded(mut input: impl Read, limit: usize) -> Result<Vec<u8>> {
    let mut output = Vec::new();
    let mut chunk = [0; 64 * 1024];
    let mut overflow = false;
    loop {
        let n = input.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        if n > limit.saturating_sub(output.len()) {
            overflow = true;
        }
        if !overflow {
            output.extend_from_slice(&chunk[..n]);
        }
    }
    if overflow {
        return Err(BridgeError::new(
            "helper_output",
            "The minipro output exceeded its safe size limit.",
        ));
    }
    Ok(output)
}

/// NDJSON can span arbitrary read boundaries, including UTF-8 codepoints.
/// A malformed/oversized line is ignored, while subsequent lines still flow.
fn decode_events(input: impl Read, event: &mut impl FnMut(Value)) -> Result<()> {
    let mut reader = BufReader::new(input);
    let mut pending = Vec::new();
    let mut oversized = false;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            break;
        }
        let newline = available.iter().position(|b| *b == b'\n');
        let consumed = newline.map_or(available.len(), |n| n + 1);
        let bytes = &available[..consumed];
        if bytes.len() > MAX_EVENT.saturating_sub(pending.len()) {
            oversized = true;
        }
        if !oversized {
            pending.extend_from_slice(bytes);
        }
        reader.consume(consumed);
        if newline.is_some() {
            if !oversized {
                emit_event(&pending, event);
            }
            pending.clear();
            oversized = false;
        }
    }
    if !oversized && !pending.is_empty() {
        emit_event(&pending, event);
    }
    Ok(())
}

fn emit_event(bytes: &[u8], event: &mut impl FnMut(Value)) {
    if let Ok(value) = serde_json::from_slice::<Value>(bytes) {
        if value.is_object()
            && ["stage", "progress", "warn", "note"]
                .iter()
                .any(|key| value.get(key).is_some())
        {
            event(value);
        }
    }
}

fn decode_result(output: &[u8], success: bool) -> Result<Value> {
    let value: Value = serde_json::from_slice(output).map_err(|_| {
        BridgeError::new("helper_protocol", "minipro did not return a JSON result.")
    })?;
    if !value.is_object() {
        return Err(BridgeError::new(
            "helper_protocol",
            "minipro returned an invalid result.",
        ));
    }
    if success && value["ok"].as_bool() == Some(true) {
        return Ok(value);
    }
    let mut error = BridgeError::new(
        value["code"].as_str().unwrap_or("helper_failure"),
        value["msg"]
            .as_str()
            .unwrap_or("The minipro operation failed."),
    );
    error.hint = value["hint"].as_str().map(str::to_owned);
    // The CLI's optional expert bypasses are never available in the GUI.
    // Do not suggest an unsafe override that the bridge deliberately forbids.
    if error
        .hint
        .as_ref()
        .is_some_and(|s| s.contains("--force") || s.contains("--skip-pincheck"))
    {
        error.hint = Some(
            "Check the exact chip marking, orientation, adapter and socket contacts, then retry."
                .into(),
        );
    }
    if cfg!(windows)
        && ["usb", "transport", "no_device", "device_not_found"].contains(&error.code.as_str())
    {
        error.hint = Some("Close other programmer apps and reconnect the T76 directly. Its USB interface must use WinUSB; see the Windows driver setup and restore instructions.".into());
    }
    if cfg!(target_os = "linux")
        && ["usb", "transport", "no_device", "device_not_found"].contains(&error.code.as_str())
    {
        error.hint = Some("Connect the T76 and install the supplied a466:1a86 udev rule, then reconnect it. Run XGecu Pro as your normal user.".into());
    }
    Err(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ndjson_handles_fragmentation_crlf_and_unterminated_final_line() {
        struct Fragmented<'a>(&'a [u8]);
        impl Read for Fragmented<'_> {
            fn read(&mut self, out: &mut [u8]) -> std::io::Result<usize> {
                let n = out.len().min(self.0.len()).min(1);
                out[..n].copy_from_slice(&self.0[..n]);
                self.0 = &self.0[n..];
                Ok(n)
            }
        }
        let mut seen = vec![];
        decode_events(Fragmented("{\"stage\":\"Loading База\"}\r\ninvalid\n{\"progress\":{\"done\":1,\"total\":2}}\n{\"note\":\"done\"}".as_bytes()), &mut |v|seen.push(v)).unwrap();
        assert_eq!(seen.len(), 3);
        assert_eq!(seen[0]["stage"], "Loading База");
        assert_eq!(seen[2]["note"], "done");
    }
    #[test]
    fn oversized_event_is_dropped_without_losing_next_event() {
        let mut bytes = vec![b'x'; MAX_EVENT + 1];
        bytes.extend_from_slice(b"\n{\"note\":\"next\"}\n");
        let mut seen = vec![];
        decode_events(&bytes[..], &mut |v| seen.push(v)).unwrap();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0]["note"], "next");
    }
    #[test]
    fn helper_failure_and_malformed_or_unsuccessful_results_reject() {
        assert_eq!(
            decode_result(b"not json", false).unwrap_err().code,
            "helper_protocol"
        );
        assert!(decode_result(b"{\"ok\":true}", false).is_err());
        let error=decode_result(b"{\"ok\":false,\"code\":\"chip_id_mismatch\",\"msg\":\"Wrong chip\",\"hint\":\"use --force\"}",false).unwrap_err();
        assert_eq!(error.code, "chip_id_mismatch");
        assert!(!error.hint.unwrap().contains("--force"));
        assert!(decode_result(b"{\"ok\":true,\"op\":\"info\"}", true).is_ok());
    }
    #[test]
    fn output_is_drained_even_after_limit() {
        assert!(read_bounded(&b"12345"[..], 4).is_err());
        assert_eq!(read_bounded(&b"1234"[..], 4).unwrap(), b"1234");
    }
    #[test]
    fn helper_is_argument_based_and_safety_environment_is_forced() {
        let runner = Runner {
            executable: PathBuf::from("/bundled/minipro"),
            extractor_dir: None,
        };
        let command = runner.command(
            &["describe".into(), "CHIP; echo surprise".into()],
            Some(Path::new("/db with space")),
        );
        let args: Vec<_> = command.get_args().collect();
        assert_eq!(
            args,
            [
                "--json",
                "--db",
                "/db with space",
                "describe",
                "CHIP; echo surprise"
            ]
        );
        let vars: std::collections::BTreeMap<_, _> = command
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().to_string(),
                    v.map(|s| s.to_string_lossy().to_string()),
                )
            })
            .collect();
        assert_eq!(vars["MINIPRO_DB_URL"], None);
        assert_eq!(vars["MINIPRO_REQUIRE_MODEL"], Some("T76".into()));
        assert_eq!(vars["MINIPRO_REQUIRE_CHIP_ID"], Some("1".into()));
        assert_eq!(vars["MINIPRO_TRUST_PINNED_DB_ONLY"], Some("1".into()));
    }
    #[test]
    fn missing_helper_is_a_typed_error() {
        let directory = tempfile::tempdir().unwrap();
        let runner = Runner {
            executable: directory.path().join("not-installed"),
            extractor_dir: None,
        };
        assert_eq!(
            runner
                .run(&["search".into(), "".into()], None, |_| {})
                .unwrap_err()
                .code,
            "helper_start"
        );
    }
    #[cfg(unix)]
    fn helper_fixture(contents: &str) -> (tempfile::TempDir, Runner) {
        use std::os::unix::fs::PermissionsExt;
        let directory = tempfile::tempdir().unwrap();
        let executable = directory.path().join("fixture-helper");
        std::fs::write(&executable, contents).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        (
            directory,
            Runner {
                executable,
                extractor_dir: None,
            },
        )
    }
    #[cfg(unix)]
    #[test]
    fn subprocess_drains_large_progress_stream_and_returns_result() {
        let (_directory, runner) = helper_fixture(
            r#"#!/bin/sh
n=0
while [ "$n" -lt 3000 ]; do
  printf '{"progress":{"done":1,"total":2}}\n' >&2
  n=$((n + 1))
done
printf '{"ok":true,"op":"search","hits":[]}\n'
"#,
        );
        let mut events = 0;
        let value = runner
            .run(&["search".into(), "".into()], None, |_| events += 1)
            .unwrap();
        assert_eq!(events, 3000);
        assert_eq!(value["ok"], true);
    }
    #[cfg(unix)]
    #[test]
    fn subprocess_exit_failure_preserves_json_error_and_rejects_bad_output() {
        let (_directory,runner)=helper_fixture("#!/bin/sh\nprintf '{\"ok\":false,\"code\":\"chip_id_mismatch\",\"msg\":\"Wrong chip\"}\\n'\nexit 7\n");
        assert_eq!(
            runner
                .run(&["search".into(), "".into()], None, |_| {})
                .unwrap_err()
                .code,
            "chip_id_mismatch"
        );
        let (_directory, runner) = helper_fixture("#!/bin/sh\nprintf 'not json\\n'\n");
        assert_eq!(
            runner
                .run(&["search".into(), "".into()], None, |_| {})
                .unwrap_err()
                .code,
            "helper_protocol"
        );
    }
}
