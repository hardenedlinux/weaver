//! Delivery/cancellation linearize at the shared admission gate; ready is not use.
use super::{Phase, Reply, Shared, State};
use crate::{BoundSource, SourceError};
use std::{
    future::Future,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::sync::oneshot;
use tokio_util::sync::WaitForCancellationFutureOwned;
/// Scheduling failures contain no source content or permission claims.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum SourceJobError {
    #[error("source owner capacity exhausted")]
    Busy,
    #[error("source owner closed")]
    Closed,
    #[error("source request cancelled")]
    Cancelled,
    #[error("source compiler result unavailable")]
    Unavailable,
    #[error("source result already observed")]
    Finished,
    #[error("source compiler rejected: {0}")]
    Source(#[from] SourceError),
}
/// Await Rust-owned, original-bound data. Dropping this future cancels delivery;
/// it does not interrupt foreign code or establish no-execution/budget evidence.
pub struct SourceJob {
    receiver: oneshot::Receiver<Reply>,
    shared: Arc<Shared>,
    state: Arc<State>,
    shutdown: Pin<Box<WaitForCancellationFutureOwned>>,
    finished: bool,
}
impl SourceJob {
    pub(super) fn new(
        receiver: oneshot::Receiver<Reply>,
        shared: Arc<Shared>,
        state: Arc<State>,
    ) -> Self {
        let shutdown = Box::pin(shared.shutdown.clone().cancelled_owned());
        Self {
            receiver,
            shared,
            state,
            shutdown,
            finished: false,
        }
    }
    /// Cancel queued/running/ready work. Delivery that already completed cannot
    /// be recalled; its inert data still needs current publication/use checks.
    pub fn cancel(&mut self) {
        {
            let _gate = self.shared.gate();
            let mut phase = self.state.guard();
            if *phase != Phase::Delivered {
                *phase = Phase::Cancelled;
            }
        }
        self.receiver.close();
    }
    fn claim(&self, reply: Reply) -> Result<BoundSource, SourceJobError> {
        let closed = self.shared.gate();
        let mut phase = self.state.guard();
        if *closed {
            return Err(SourceJobError::Closed);
        }
        if *phase == Phase::Cancelled {
            return Err(SourceJobError::Cancelled);
        }
        if *phase != Phase::Ready {
            return Err(SourceJobError::Unavailable);
        }
        *phase = Phase::Delivered;
        reply.result
    }
}
impl Future for SourceJob {
    type Output = Result<BoundSource, SourceJobError>;
    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output> {
        if self.finished {
            return Poll::Ready(Err(SourceJobError::Finished));
        }
        if self.shutdown.as_mut().poll(cx).is_ready() {
            self.cancel();
            self.finished = true;
            return Poll::Ready(Err(SourceJobError::Closed));
        }
        let result = match Pin::new(&mut self.receiver).poll(cx) {
            Poll::Pending => return Poll::Pending,
            Poll::Ready(Ok(reply)) => self.claim(reply),
            Poll::Ready(Err(_)) => {
                if *self.state.guard() == Phase::Cancelled {
                    Err(SourceJobError::Cancelled)
                } else {
                    Err(SourceJobError::Unavailable)
                }
            }
        };
        self.finished = true;
        Poll::Ready(result)
    }
}
impl Drop for SourceJob {
    fn drop(&mut self) {
        if !self.finished {
            self.cancel();
        }
    }
}
