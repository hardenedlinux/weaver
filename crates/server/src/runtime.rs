//! Typed runtime owner: bounded task admission, cancellation, tracking and drain acknowledgment.
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, Ordering},
};
use tokio::sync::OwnedSemaphorePermit;
use tokio_util::{sync::CancellationToken, task::TaskTracker};
use weaver_contracts::{Error, Result};
use weaver_governance::{ProducerClient, SourceClient};

#[derive(Clone)]
/// Shared terminal task/resource owner, exported as `ServiceRuntime` for embedding.
pub struct RuntimeOwner {
    inner: Arc<Inner>,
}
struct Inner {
    gate: Mutex<AdmissionState>,
    closed: AtomicBool,
    cancel: CancellationToken,
    tasks: TaskTracker,
}
struct AdmissionState {
    governance: Option<SourceClient>,
    producers: Option<ProducerClient>,
}
pub(crate) struct ShutdownGuard {
    runtime: Option<RuntimeOwner>,
}
impl ShutdownGuard {
    pub(crate) fn disarm(&mut self) {
        self.runtime = None;
    }
}
impl Drop for ShutdownGuard {
    fn drop(&mut self) {
        if let Some(runtime) = &self.runtime {
            runtime.request_shutdown();
        }
    }
}
impl Default for RuntimeOwner {
    fn default() -> Self {
        Self::new()
    }
}
impl RuntimeOwner {
    pub(crate) fn shutdown_guard(&self) -> ShutdownGuard {
        ShutdownGuard {
            runtime: Some(self.clone()),
        }
    }
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
    /// Create the shared tracked owner for RPC, execution and governance resources.
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Inner {
                gate: Mutex::new(AdmissionState {
                    governance: None,
                    producers: None,
                }),
                closed: AtomicBool::new(false),
                cancel: CancellationToken::new(),
                tasks: TaskTracker::new(),
            }),
        }
    }
    /// Terminal resource state; it is not execution or no-execution evidence.
    pub fn closing(&self) -> bool {
        self.inner.closed.load(Ordering::Acquire) || self.inner.cancel.is_cancelled()
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
    pub(crate) fn attach_governance(&self, client: SourceClient) -> Result<()> {
        let mut state = self
            .inner
            .gate
            .lock()
            .map_err(|_| Error::Conflict("runtime owner poisoned"))?;
        if self.closing() {
            return Err(Error::Conflict("runtime admission closed"));
        }
        if state.governance.is_some() {
            return Err(Error::Conflict("governance owner already installed"));
        }
        state.governance = Some(client);
        Ok(())
    }
    pub(crate) fn install_producers(&self, client: ProducerClient) -> Result<()> {
        let mut state = self
            .inner
            .gate
            .lock()
            .map_err(|_| Error::Conflict("runtime owner poisoned"))?;
        if self.closing() {
            return Err(Error::Conflict("runtime admission closed"));
        }
        if state.producers.is_some() {
            return Err(Error::Conflict("producer catalog already installed"));
        }
        state.producers = Some(client);
        Ok(())
    }
    /// Observe the sealed producer set installed by the initialized compiler
    /// guard. This is not a source-authority observation or final-use permit.
    pub fn producers(&self) -> Result<ProducerClient> {
        let state = self
            .inner
            .gate
            .lock()
            .map_err(|_| Error::Conflict("runtime owner poisoned"))?;
        if self.closing() {
            return Err(Error::Conflict("runtime admission closed"));
        }
        state
            .producers
            .clone()
            .ok_or(Error::Conflict("producer catalog not installed"))
    }
    /// Close attached source delivery and task admission before returning.
    /// This notification does not acknowledge foreign-call cleanup or drain.
    pub fn request_shutdown(&self) {
        // Poison closes admission; it must never suppress cancellation or task draining.
        let governance = {
            let gate = self.inner.gate.lock().unwrap_or_else(|e| e.into_inner());
            self.inner.closed.store(true, Ordering::Release);
            gate.governance.clone()
        };
        // Never invoke cancellation wakers under the admission mutex. Repeated
        // shutdown callers each close the lane before acknowledging notification.
        if let Some(client) = governance {
            client.close();
        }
        self.inner.cancel.cancel();
        self.inner.tasks.close();
    }
    /// Wait for all tracked owners, including natural Scheme cleanup.
    pub async fn drain(&self) {
        self.request_shutdown();
        self.inner.tasks.wait().await;
    }
}

#[cfg(test)]
#[path = "../tests/unit/runtime_lifecycle.rs"]
mod tests;
