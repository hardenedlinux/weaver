// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed runtime owner: bounded task admission, cancellation, tracking and drain acknowledgment.
use std::sync::{
    Arc, Mutex, OnceLock,
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
    telemetry: Arc<weaver_telemetry::Metrics>,
    gate: Mutex<AdmissionState>,
    closed: AtomicBool,
    cancel: CancellationToken,
    tasks: TaskTracker,
    single_provider: OnceLock<crate::single_provider::SingleProvider>,
    fact_feed: OnceLock<weaver_contracts::FactFeed>,
    session_wakeup: Arc<tokio::sync::Notify>,
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
                telemetry: Arc::new(weaver_telemetry::Metrics::default()),
                gate: Mutex::new(AdmissionState {
                    governance: None,
                    producers: None,
                }),
                closed: AtomicBool::new(false),
                cancel: CancellationToken::new(),
                tasks: TaskTracker::new(),
                single_provider: OnceLock::new(),
                fact_feed: OnceLock::new(),
                session_wakeup: Arc::new(tokio::sync::Notify::new()),
            }),
        }
    }
    pub(crate) fn install_fact_feed(&self, feed: weaver_contracts::FactFeed) -> Result<()> {
        self.inner
            .fact_feed
            .set(feed)
            .map_err(|_| Error::Conflict("fact feed already installed"))
    }
    pub(crate) fn fact_feed(&self) -> Option<&weaver_contracts::FactFeed> {
        self.inner.fact_feed.get()
    }
    pub(crate) fn session_wakeup(&self) -> Option<&Arc<tokio::sync::Notify>> {
        self.fact_feed()
            .filter(|feed| !feed.workflow_path.is_empty())
            .map(|_| &self.inner.session_wakeup)
    }
    pub(crate) fn wake_session(&self) {
        if let Some(wakeup) = self.session_wakeup() {
            wakeup.notify_one();
        }
    }
    #[cfg(any(feature = "scheme-program", test))]
    pub(crate) fn enable_single_provider(&self) -> Result<()> {
        self.inner
            .single_provider
            .set(crate::single_provider::SingleProvider::default())
            .map_err(|_| Error::Conflict("single-provider lifecycle already installed"))
    }
    pub(crate) fn single_provider(&self) -> Option<&crate::single_provider::SingleProvider> {
        self.inner.single_provider.get()
    }
    pub(crate) async fn retire_single_provider(&self) -> Result<()> {
        let lifecycle = self
            .single_provider()
            .ok_or(Error::Conflict("single-provider lifecycle unavailable"))?;
        let client = self
            .inner
            .gate
            .lock()
            .map_err(|_| Error::Conflict("runtime owner poisoned"))?
            .governance
            .clone()
            .ok_or(Error::Conflict("governance owner unavailable"))?;
        lifecycle.request_retirement();
        client.close();
        tokio::select! {
            biased;
            _ = lifecycle.retired() => Ok(()),
            _ = self.cancellation() => Err(Error::Conflict("governance retirement interrupted")),
        }
    }
    /// Bounded local observations only; callers acquire no authority capability.
    pub fn telemetry(&self) -> &Arc<weaver_telemetry::Metrics> {
        &self.inner.telemetry
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
    pub(crate) fn governor(&self) -> Result<SourceClient> {
        self.inner
            .gate
            .lock()
            .map_err(|_| Error::Conflict("runtime owner poisoned"))?
            .governance
            .clone()
            .ok_or(Error::Conflict("governance owner unavailable"))
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
