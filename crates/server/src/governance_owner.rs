// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One terminal semantic compiler tracked by the existing service runtime.
use crate::runtime::RuntimeOwner;
use std::{num::NonZeroUsize, sync::Arc};
use tokio::sync::{OwnedSemaphorePermit, oneshot};
use weaver_contracts::{Error, Result};
use weaver_governance::{
    OwnedSource, ProducerCatalog, ProducerClient, SourceClient, SourceError, source_lane,
};

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
        self.start_governance_with_governor(
            slot,
            capacity,
            initialize,
            |compiler, original, _| compiler(original),
            |_, _| Err(SourceError::Contract),
        )
        .await
    }

    pub(crate) async fn start_governance_with_governor<C: 'static>(
        &self,
        slot: Arc<OwnedSemaphorePermit>,
        capacity: NonZeroUsize,
        initialize: impl FnOnce() -> Result<C> + Send + 'static,
        compile: impl FnMut(
            &mut C,
            &OwnedSource,
            &tokio_util::sync::CancellationToken,
        ) -> std::result::Result<OwnedSource, SourceError>
        + Send
        + 'static,
        derive: impl FnMut(
            &mut C,
            &weaver_governance::Derivation,
        ) -> std::result::Result<Vec<String>, SourceError>
        + Send
        + 'static,
    ) -> Result<GovernanceWorker> {
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
            inbox.run_with_cancellable_governor(compiler, compile, derive);
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
    /// Install the immutable approved set for this initialized compiler. Only
    /// the trusted embedding can call this; no module path/export comes from RPC.
    /// A runtime cannot replace its installed catalog or reinterpret an old name.
    pub fn publish_producers(&self, catalog: ProducerCatalog) -> Result<ProducerClient> {
        let client = catalog.bind(self.client.clone());
        self.runtime.install_producers(client.clone())?;
        Ok(client)
    }
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
