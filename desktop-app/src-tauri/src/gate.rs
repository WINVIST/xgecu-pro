use crate::{
    error::{BridgeError, Result},
    transaction::PreparedProgram,
};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Gate {
    busy: bool,
    closing: bool,
    dirty: bool,
    pending: Option<PreparedProgram>,
}

#[derive(Default)]
pub struct OperationGate(Mutex<Gate>);

pub struct Permit(Arc<OperationGate>);
impl Drop for Permit {
    fn drop(&mut self) {
        if let Ok(mut gate) = self.0 .0.lock() {
            gate.busy = false;
        }
    }
}

impl OperationGate {
    pub fn start(self: &Arc<Self>) -> Result<Permit> {
        let mut gate = self
            .0
            .lock()
            .map_err(|_| BridgeError::new("state", "The operation state is unavailable."))?;
        if gate.closing {
            return Err(BridgeError::new("closing", "The application is closing."));
        }
        if gate.busy || gate.pending.is_some() {
            return Err(BridgeError::new(
                "busy",
                "Finish or cancel the current operation first.",
            ));
        }
        gate.busy = true;
        Ok(Permit(self.clone()))
    }
    pub fn prepare(&self, program: PreparedProgram) -> Result<()> {
        let mut gate = self
            .0
            .lock()
            .map_err(|_| BridgeError::new("state", "The operation state is unavailable."))?;
        if !gate.busy || gate.pending.is_some() {
            return Err(BridgeError::new(
                "state",
                "The programming preparation lost its operation lock.",
            ));
        }
        gate.pending = Some(program);
        Ok(())
    }
    pub fn consume(self: &Arc<Self>, token: &str) -> Result<(Permit, PreparedProgram)> {
        let mut gate = self
            .0
            .lock()
            .map_err(|_| BridgeError::new("state", "The operation state is unavailable."))?;
        if gate.busy || gate.closing {
            return Err(BridgeError::new(
                "busy",
                "Finish the current operation first.",
            ));
        }
        let pending = gate.pending.as_ref().ok_or_else(|| {
            BridgeError::new("invalid_token", "No programming confirmation is pending.")
        })?;
        if pending.token != token {
            return Err(BridgeError::new(
                "invalid_token",
                "The programming confirmation has expired or is invalid.",
            ));
        }
        let pending = gate.pending.take().ok_or_else(|| {
            BridgeError::new("invalid_token", "No programming confirmation is pending.")
        })?;
        gate.busy = true;
        Ok((Permit(self.clone()), pending))
    }
    pub fn set_dirty(&self, dirty: bool) -> Result<()> {
        let mut gate = self
            .0
            .lock()
            .map_err(|_| BridgeError::new("state", "The operation state is unavailable."))?;
        gate.dirty = dirty;
        Ok(())
    }
    pub fn closing(&self) -> bool {
        self.0.lock().map(|gate| gate.closing).unwrap_or(false)
    }
    pub fn allow_close(&self, discard: bool) -> Result<()> {
        let mut gate = self
            .0
            .lock()
            .map_err(|_| BridgeError::new("state", "The operation state is unavailable."))?;
        if gate.busy || gate.pending.is_some() {
            return Err(BridgeError::new(
                "busy",
                "Keep the application open until the operation or confirmation finishes.",
            ));
        }
        if gate.dirty && !discard {
            return Err(BridgeError::new(
                "unsaved_buffer",
                "The image buffer has unsaved changes.",
            ));
        }
        gate.closing = true;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn program(parent: &std::path::Path) -> PreparedProgram {
        PreparedProgram {
            token: "one-use-token".into(),
            chip: "TEST".into(),
            image: "image".into(),
            database: "db".into(),
            format: "raw",
            image_digest: "".into(),
            database_digest: "".into(),
            _directory: crate::transaction::PrivateDirectory::new(parent).unwrap(),
        }
    }
    #[test]
    fn one_operation_including_buffer_work_blocks_parallel_start_and_close() {
        let gate = Arc::new(OperationGate::default());
        let permit = gate.start().unwrap();
        assert!(gate.start().is_err());
        assert!(gate.allow_close(false).is_err());
        drop(permit);
        assert!(gate.start().is_ok());
    }
    #[test]
    fn pending_snapshot_blocks_work_and_bad_token_cannot_consume_it() {
        let dir = tempfile::tempdir().unwrap();
        let gate = Arc::new(OperationGate::default());
        let permit = gate.start().unwrap();
        gate.prepare(program(dir.path())).unwrap();
        drop(permit);
        assert!(gate.start().is_err());
        assert!(gate.allow_close(false).is_err());
        assert!(gate.consume("wrong").is_err());
        let (permit, pending) = gate.consume("one-use-token").unwrap();
        assert!(gate.consume("one-use-token").is_err());
        drop(pending);
        drop(permit);
        assert!(gate.consume("one-use-token").is_err());
        assert!(gate.start().is_ok());
        assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    }
    #[test]
    fn close_locks_out_racing_operations() {
        let gate = Arc::new(OperationGate::default());
        gate.allow_close(false).unwrap();
        assert!(gate.start().is_err());
    }
    #[test]
    fn dirty_state_and_close_decision_share_one_lock() {
        let gate = Arc::new(OperationGate::default());
        let permit = gate.start().unwrap();
        gate.set_dirty(true).unwrap();
        assert_eq!(gate.allow_close(true).unwrap_err().code, "busy");
        drop(permit);
        assert_eq!(gate.allow_close(false).unwrap_err().code, "unsaved_buffer");
        assert!(!gate.closing());
        gate.allow_close(true).unwrap();
        assert!(gate.start().is_err());
    }
}
