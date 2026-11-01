//! One blocking loop; the embedding runtime owns thread tracking and VM cleanup.
use super::{Command, Phase, Reply, Shared, SourceJobError, Work};
use crate::{OwnedSource, SourceError};
use std::sync::Arc;
use tokio::sync::mpsc;
/// Move this receiver to the existing tracked blocking owner before constructing
/// its VM. The compiler can borrow that thread-affine, non-Send runtime.
pub struct SourceInbox {
    pub(super) receiver: mpsc::Receiver<Command>,
    pub(super) shared: Arc<Shared>,
}
impl SourceInbox {
    /// Run synchronous approved compilation. No lock is held during foreign
    /// calls or content comparison. Finish/VM cleanup must precede owner join ack.
    /// This does not sandbox arbitrary callbacks or implement source authenticity.
    pub fn run(
        mut self,
        mut compile: impl FnMut(&OwnedSource) -> Result<OwnedSource, SourceError>,
    ) {
        while let Some(command) = self.receiver.blocking_recv() {
            if *self.shared.gate() {
                break;
            }
            match command {
                Command::Stop => break,
                Command::Compile(work) => self.execute(*work, &mut compile),
            }
            if *self.shared.gate() {
                break;
            }
        }
    }
    fn execute(
        &self,
        work: Work,
        compile: &mut impl FnMut(&OwnedSource) -> Result<OwnedSource, SourceError>,
    ) {
        {
            let closed = self.shared.gate();
            let mut phase = work.state.guard();
            if *closed || *phase == Phase::Cancelled {
                return;
            }
            *phase = Phase::Running;
        }
        let result = compile(&work.original)
            .and_then(|candidate| work.expected.bind(candidate))
            .map_err(SourceJobError::from);
        if matches!(result, Err(SourceJobError::Source(SourceError::Scheme))) {
            self.shared.stop();
        }
        {
            let closed = self.shared.gate();
            let mut phase = work.state.guard();
            if *closed || *phase == Phase::Cancelled {
                return;
            }
            *phase = Phase::Ready;
        }
        // Waking a caller happens outside all gates. The future rechecks them
        // when it claims the result, closing ready/send versus close/cancel races.
        let _ = work.reply.send(Reply {
            result,
            _slot: work.slot,
        });
    }
}
impl Drop for SourceInbox {
    fn drop(&mut self) {
        self.shared.stop();
    }
}
