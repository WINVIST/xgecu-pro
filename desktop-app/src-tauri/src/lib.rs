mod driver;
mod error;
mod gate;
mod hex;
mod policy;
mod runner;
mod settings;
mod transaction;

use crate::{
    error::{BridgeError, Result},
    gate::OperationGate,
    hex::{BufferReply, BufferRequest, HexBuffer},
    policy::{Operation, ProgrammerRequest},
    runner::Runner,
    settings::Settings,
    transaction::{PreparedProgram, PreparedReply, PrivateDirectory},
};
use serde_json::{json, Value};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
use tauri::{AppHandle, Emitter, Manager};

struct BridgeState {
    gate: Arc<OperationGate>,
    buffer: Mutex<HexBuffer>,
    settings_file: PathBuf,
    scratch: PathBuf,
}

fn emit(app: &AppHandle, event: Value) {
    let _ = app.emit("operation-event", event);
}
fn run_helper(
    app: &AppHandle,
    args: &[std::ffi::OsString],
    database: Option<&Path>,
) -> Result<Value> {
    Runner::resolve(app)?.run(args, database, |event| emit(app, event))
}
fn database(value: Option<&str>) -> Result<Option<PathBuf>> {
    value
        .filter(|s| !s.is_empty())
        .map(|s| std::fs::canonicalize(s).map_err(BridgeError::from))
        .transpose()
}
async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T> + Send + 'static,
) -> Result<T> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|e| BridgeError::new("worker", format!("The background operation failed: {e}")))?
}

#[tauri::command]
async fn get_settings(app: AppHandle) -> Result<Settings> {
    blocking(move || settings::load(&app.state::<BridgeState>().settings_file)).await
}

#[tauri::command]
async fn save_settings(app: AppHandle, settings: Settings) -> Result<Settings> {
    let permit = app.state::<BridgeState>().gate.start()?;
    blocking(move || {
        let _permit = permit;
        settings::save(&app.state::<BridgeState>().settings_file, settings)
    })
    .await
}

#[tauri::command]
async fn inspect_file(app: AppHandle, file: String) -> Result<policy::FileInfo> {
    let permit = app.state::<BridgeState>().gate.start()?;
    blocking(move || {
        let _permit = permit;
        policy::inspect_image(&file)
    })
    .await
}

#[tauri::command]
async fn programmer_run(app: AppHandle, request: ProgrammerRequest) -> Result<Value> {
    let permit = app.state::<BridgeState>().gate.start()?;
    blocking(move || {
        let _permit = permit;
        let db = database(request.database.as_deref())?;
        let args = policy::arguments(&request)?;
        if matches!(
            request.operation,
            Operation::Read
                | Operation::Verify
                | Operation::Blank
                | Operation::Check
                | Operation::Erase
        ) {
            let chip = policy::chip_name(request.chip.as_deref())?;
            let details = run_helper(&app, &["describe".into(), chip.into()], db.as_deref())?;
            policy::enforce_capability(
                &details,
                chip,
                request.operation == Operation::Erase,
                request.operation == Operation::Erase,
            )?;
        }
        run_helper(&app, &args, db.as_deref())
    })
    .await
}

#[tauri::command]
async fn prepare_program(
    app: AppHandle,
    chip: String,
    file: String,
    database: String,
) -> Result<PreparedReply> {
    let permit = app.state::<BridgeState>().gate.start()?;
    blocking(move || {
        let _permit = permit;
        policy::chip_name(Some(&chip))?;
        let selected_database = crate::database(Some(&database))?;
        // The first describe prepares the pinned cache if necessary. The
        // second describe and all hardware work use the private DB snapshot.
        let details = run_helper(
            &app,
            &["describe".into(), chip.clone().into()],
            selected_database.as_deref(),
        )?;
        policy::enforce_capability(&details, &chip, true, false)?;
        let state = app.state::<BridgeState>();
        emit(
            &app,
            json!({"stage":"Preparing private firmware and database snapshots"}),
        );
        let directory = PrivateDirectory::new(&state.scratch)?;
        let source = policy::input_file(Some(&file))?;
        let format = policy::input_format(&source);
        let (image, bytes, image_digest) = transaction::snapshot_image(&source, directory.path())?;
        let database_source = selected_database
            .map(Ok)
            .unwrap_or_else(transaction::default_database)?;
        let database = transaction::snapshot_database(&database_source, directory.path())?;
        let database_digest = transaction::tree_digest(&database)?;
        let details = run_helper(
            &app,
            &["describe".into(), chip.clone().into()],
            Some(&database),
        )?;
        policy::enforce_capability(&details, &chip, true, false)?;
        let token = uuid::Uuid::new_v4().to_string();
        let prepared = PreparedProgram {
            token: token.clone(),
            chip: chip.clone(),
            image,
            database,
            format,
            image_digest,
            database_digest,
            _directory: directory,
        };
        run_helper(&app, &prepared.arguments(true), Some(&prepared.database))?;
        prepared.validate()?;
        state.gate.prepare(prepared)?;
        Ok(PreparedReply {
            token,
            chip,
            file,
            bytes,
        })
    })
    .await
}

#[tauri::command]
async fn commit_program(app: AppHandle, token: String) -> Result<Value> {
    let (permit, prepared) = app.state::<BridgeState>().gate.consume(&token)?;
    blocking(move || {
        let _permit = permit;
        prepared.validate()?;
        let result = run_helper(&app, &prepared.arguments(false), Some(&prepared.database));
        drop(prepared);
        result
    })
    .await
}

#[tauri::command]
async fn cancel_program(app: AppHandle, token: String) -> Result<()> {
    let (permit, prepared) = app.state::<BridgeState>().gate.consume(&token)?;
    blocking(move || {
        let _permit = permit;
        drop(prepared);
        Ok(())
    })
    .await
}

#[tauri::command]
async fn buffer_command(app: AppHandle, request: BufferRequest) -> Result<BufferReply> {
    let permit = app.state::<BridgeState>().gate.start()?;
    blocking(move || {
        let _permit = permit;
        execute_buffer(&app.state::<BridgeState>(), request)
    })
    .await
}

fn execute_buffer(state: &BridgeState, request: BufferRequest) -> Result<BufferReply> {
    let mut buffer = state.buffer.lock().map_err(|_| {
        // An unknown buffer state must never allow an implicit discard.
        let _ = state.gate.set_dirty(true);
        BridgeError::new("buffer", "The image buffer is unavailable.")
    })?;
    let result = buffer.execute(request);
    // A mutation can succeed before reply hashing/page I/O fails. Preserve
    // the unsaved-close guard even when there is no successful reply.
    state.gate.set_dirty(buffer.is_dirty())?;
    result.map_err(|message| BridgeError::new("buffer", message))
}

#[tauri::command]
async fn save_text_file(app: AppHandle, file: String, contents: String) -> Result<()> {
    if contents.len() > 4 * 1024 * 1024 {
        return Err(BridgeError::new(
            "report_too_large",
            "USB diagnostic report exceeds 4 MiB.",
        ));
    }
    let permit = app.state::<BridgeState>().gate.start()?;
    blocking(move || {
        let _permit = permit;
        let path = policy::output_file(Some(&file))?;
        let parent = path
            .parent()
            .ok_or_else(|| BridgeError::new("invalid_file", "Choose a destination directory."))?;
        let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
        temporary.write_all(contents.as_bytes())?;
        temporary.as_file().sync_all()?;
        temporary
            .persist(path)
            .map_err(|e| BridgeError::from(e.error))?;
        Ok(())
    })
    .await
}

#[tauri::command]
fn allow_close(app: AppHandle, discard: bool) -> Result<()> {
    let state = app.state::<BridgeState>();
    state.gate.allow_close(discard)?;
    app.exit(0);
    Ok(())
}

fn prevent_close(app: &AppHandle) -> bool {
    let state = app.state::<BridgeState>();
    if state.gate.closing() {
        return false;
    }
    match state.gate.allow_close(false) {
        Ok(()) => false,
        Err(error) => {
            if error.code == "unsaved_buffer" {
                let _ = app.emit("close-requested", json!({"dirty":true}));
            } else {
                emit(
                    app,
                    json!({"note":"Keep XGecu Pro open until the operation or programming confirmation finishes."}),
                );
            }
            true
        }
    }
}

pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let settings_file = app.path().app_config_dir()?.join("settings.json");
            let scratch = app
                .path()
                .app_local_data_dir()?
                .join("private-transactions");
            fs::create_dir_all(&scratch)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&scratch, fs::Permissions::from_mode(0o700))?;
            }
            app.manage(BridgeState {
                gate: Arc::new(OperationGate::default()),
                buffer: Mutex::new(HexBuffer::new()),
                settings_file,
                scratch,
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_settings,
            save_settings,
            inspect_file,
            programmer_run,
            prepare_program,
            commit_program,
            cancel_program,
            buffer_command,
            save_text_file,
            allow_close
        ])
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if prevent_close(window.app_handle()) {
                    api.prevent_close();
                }
            }
        })
        .build(tauri::generate_context!());
    match app {
        Ok(app) => app.run(|app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                if prevent_close(app) {
                    api.prevent_exit();
                }
            }
        }),
        Err(error) => {
            eprintln!("XGecu Pro could not start: {error}");
            std::process::exit(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn buffer_errors_synchronize_unsaved_close_protection() {
        let directory = tempfile::tempdir().unwrap();
        let file = directory.path().join("source.bin");
        fs::write(&file, b"original firmware").unwrap();
        let state = BridgeState {
            gate: Arc::new(OperationGate::default()),
            buffer: Mutex::new(HexBuffer::new()),
            settings_file: directory.path().join("settings.json"),
            scratch: directory.path().join("scratch"),
        };
        execute_buffer(
            &state,
            BufferRequest {
                operation: "open".into(),
                file: Some(file.to_string_lossy().into()),
                ..Default::default()
            },
        )
        .unwrap();
        // Model an image mutation whose response has not yet reached the
        // bridge, then ensure even a failed command synchronizes that state.
        state
            .buffer
            .lock()
            .unwrap()
            .execute(BufferRequest {
                operation: "edit".into(),
                offset: Some(0),
                value: Some(0),
                ..Default::default()
            })
            .unwrap();
        let permit = state.gate.start().unwrap();
        assert!(execute_buffer(
            &state,
            BufferRequest {
                operation: "invalid".into(),
                ..Default::default()
            }
        )
        .is_err());
        drop(permit);
        assert_eq!(
            state.gate.allow_close(false).unwrap_err().code,
            "unsaved_buffer"
        );
        state.gate.allow_close(true).unwrap();
    }
}
