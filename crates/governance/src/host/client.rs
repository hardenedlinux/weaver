//! Nonblocking source admission; capacity covers queued, active and ready data.
use super::{Command, Phase, Shared, SourceInbox, SourceJob, SourceJobError, State, Work};
use crate::{OwnedSource, SourceExpectation};
use std::{
    num::NonZeroUsize,
    sync::{Arc, Mutex},
};
use tokio::sync::{Semaphore, mpsc, oneshot};
use tokio_util::sync::CancellationToken;
/// Cloneable ingress for a single terminal owner. No Gerbil root or VM crosses it.
#[derive(Clone)]
pub struct SourceClient {
    sender: mpsc::Sender<Command>,
    shared: Arc<Shared>,
    capacity: Arc<Semaphore>,
}
/// Build a finite lane; the existing runtime owner supplies and tracks its
/// blocking worker. Capacity is an explicit host budget, not VM processor count.
pub fn source_lane(capacity: NonZeroUsize) -> (SourceClient, SourceInbox) {
    let (sender, receiver) = mpsc::channel(capacity.get());
    let shared = Arc::new(Shared {
        closed: Mutex::new(false),
        shutdown: CancellationToken::new(),
    });
    (
        SourceClient {
            sender,
            shared: shared.clone(),
            capacity: Arc::new(Semaphore::new(capacity.get())),
        },
        SourceInbox { receiver, shared },
    )
}
impl SourceClient {
    /// Capture the independently admitted original before queueing. A full or
    /// stopped lane refuses immediately; it never falls back to a process path.
    pub fn submit(&self, original: OwnedSource) -> Result<SourceJob, SourceJobError> {
        let stopped = *self.shared.gate();
        if stopped {
            return Err(SourceJobError::Closed);
        }
        let slot = self
            .capacity
            .clone()
            .try_acquire_owned()
            .map_err(|_| SourceJobError::Busy)?;
        let expected = SourceExpectation::capture(&original);
        let state = Arc::new(State {
            phase: Mutex::new(Phase::Queued),
        });
        let (reply, receiver) = oneshot::channel();
        let work = Work {
            original,
            expected,
            state: state.clone(),
            reply,
            slot,
        };
        let closed = self.shared.gate();
        if *closed {
            return Err(SourceJobError::Closed);
        }
        self.sender
            .try_send(Command::Compile(Box::new(work)))
            .map_err(|error| match error {
                mpsc::error::TrySendError::Full(_) => SourceJobError::Busy,
                mpsc::error::TrySendError::Closed(_) => SourceJobError::Closed,
            })?;
        Ok(SourceJob::new(receiver, self.shared.clone(), state))
    }
    /// Close admission and wake callers/owner. This is not drain acknowledgment;
    /// an active synchronous compiler must return and clean its VM naturally.
    pub fn close(&self) {
        self.shared.stop();
        // A full channel already contains work that wakes the owner; a spare
        // slot carries Stop to wake an idle blocking receiver.
        let _ = self.sender.try_send(Command::Stop);
    }
}
