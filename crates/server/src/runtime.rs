//! Typed runtime owner: bounded task admission, cancellation, tracking and drain acknowledgment.
use std::sync::{Arc, Mutex};
use tokio::sync::OwnedSemaphorePermit;
use tokio_util::{sync::CancellationToken, task::TaskTracker};
use weaver_contracts::{Error, Result};

#[derive(Clone)]
pub(crate) struct RuntimeOwner {
    inner: Arc<Inner>,
}
struct Inner {
    gate: Mutex<()>,
    cancel: CancellationToken,
    tasks: TaskTracker,
}
impl RuntimeOwner {
    pub(crate) async fn initialize<T: Send + 'static>(
        run: impl FnOnce() -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let owner = Self::new();
        let slot = Arc::new(
            Arc::new(tokio::sync::Semaphore::new(1))
                .try_acquire_owned()
                .map_err(|_| Error::Conflict("startup slot"))?,
        );
        let job = owner.spawn_blocking(slot, move |_| run())?;
        let result = job.await;
        owner.drain().await;
        result.map_err(|_| Error::Conflict("startup worker failed"))?
    }
    pub(crate) fn new() -> Self {
        Self {
            inner: Arc::new(Inner {
                gate: Mutex::new(()),
                cancel: CancellationToken::new(),
                tasks: TaskTracker::new(),
            }),
        }
    }
    pub(crate) fn closing(&self) -> bool {
        self.inner.cancel.is_cancelled()
    }
    pub(crate) fn cancellation(&self) -> tokio_util::sync::WaitForCancellationFutureOwned {
        self.inner.cancel.clone().cancelled_owned()
    }
    pub(crate) fn spawn_blocking<T: Send + 'static>(
        &self,
        slot: Arc<OwnedSemaphorePermit>,
        run: impl FnOnce(CancellationToken) -> Result<T> + Send + 'static,
    ) -> Result<tokio::task::JoinHandle<Result<T>>> {
        let _gate = self
            .inner
            .gate
            .lock()
            .map_err(|_| Error::Conflict("runtime owner poisoned"))?;
        if self.closing() {
            return Err(Error::Conflict("runtime admission closed"));
        }
        let cancel = self.inner.cancel.clone();
        Ok(self.inner.tasks.spawn_blocking(move || {
            let _slot = slot;
            if cancel.is_cancelled() {
                return Err(Error::Conflict("runtime cancelled before start"));
            }
            run(cancel)
        }))
    }
    pub(crate) fn request_shutdown(&self) {
        // Poison closes admission; it must never suppress cancellation or task draining.
        let _gate = self.inner.gate.lock().unwrap_or_else(|e| e.into_inner());
        self.inner.cancel.cancel();
        self.inner.tasks.close();
    }
    pub(crate) async fn drain(&self) {
        self.request_shutdown();
        self.inner.tasks.wait().await;
    }
}

#[cfg(test)]
#[path = "../tests/unit/runtime_lifecycle.rs"]
mod tests;
