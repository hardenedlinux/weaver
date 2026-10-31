//! One terminal semantic compiler tracked by the existing service runtime.
use crate::runtime::RuntimeOwner;
use std::{num::NonZeroUsize, sync::Arc};
use tokio::sync::{OwnedSemaphorePermit, oneshot};
use weaver_contracts::{Error, Result};
use weaver_governance::{OwnedSource, SourceClient, SourceError, source_lane};

/// Retain this guard for the lifetime of the approved compiler. Drop closes the
/// shared service, while the runtime continues tracking natural worker cleanup.
pub struct GovernanceWorker {
    client: SourceClient,
    runtime: RuntimeOwner,
    job: Option<tokio::task::JoinHandle<Result<()>>>,
}
impl RuntimeOwner {
    /// Construct the compiler on a tracked blocking owner. Only the factory is
    /// Send: its returned compiler may own a non-Send Scheme VM. The embedding
    /// supplies a host resource permit and explicit queue budget; neither is a
    /// VM processor override. Factory/program authenticity remains host-owned.
    pub async fn start_governance<F, C>(
        &self,
        slot: Arc<OwnedSemaphorePermit>,
        capacity: NonZeroUsize,
        initialize: F,
    ) -> Result<GovernanceWorker>
    where
        F: FnOnce() -> Result<C> + Send + 'static,
        C: FnMut(&OwnedSource) -> std::result::Result<OwnedSource, SourceError> + 'static,
    {
        let (client, inbox) = source_lane(capacity);
        self.attach_governance(client.clone())?;
        let mut starting = self.shutdown_guard();
        let exit = self.shutdown_guard();
        let (ready, receiver) = oneshot::channel();
        let job = self.spawn_blocking(slot, move |_| {
            let _exit = exit;
            let compiler = match initialize() {
                Ok(compiler) => compiler,
                Err(error) => {
                    let _ = ready.send(Err(Error::Conflict("governance initialization failed")));
                    return Err(error);
                }
            };
            if ready.send(Ok(())).is_err() {
                return Ok(());
            }
            // run drops the compiler (and its VM) before the tracked task ends.
            inbox.run(compiler);
            Ok(())
        })?;
        let initialized = receiver
            .await
            .map_err(|_| Error::Conflict("governance owner startup unavailable"))
            .and_then(|result| result);
        if let Err(error) = initialized {
            self.request_shutdown();
            let _ = job.await;
            return Err(error);
        }
        if self.closing() {
            self.request_shutdown();
            let _ = job.await;
            return Err(Error::Conflict("governance startup fenced by shutdown"));
        }
        starting.disarm();
        Ok(GovernanceWorker {
            client,
            runtime: self.clone(),
            job: Some(job),
        })
    }
}
impl GovernanceWorker {
    /// Typed inert data only; this handle cannot publish, send or release holds.
    pub fn client(&self) -> SourceClient {
        self.client.clone()
    }
    /// Close the shared runtime and wait for this owner's natural cleanup.
    /// Other owners still require ServiceRuntime::drain.
    pub async fn finish(mut self) -> Result<()> {
        self.runtime.request_shutdown();
        let job = self
            .job
            .take()
            .ok_or(Error::Conflict("governance owner already joined"))?;
        job.await
            .map_err(|_| Error::Conflict("governance owner panicked"))?
    }
}
impl Drop for GovernanceWorker {
    fn drop(&mut self) {
        self.runtime.request_shutdown();
    }
}

#[cfg(test)]
#[path = "../tests/unit/governance_owner.rs"]
mod tests;
