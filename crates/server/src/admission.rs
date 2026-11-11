// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Separate bounded native lanes keep execution saturation out of authority publication.
use std::sync::Arc;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tonic::Status;

#[derive(Clone)]
pub(crate) struct Admission {
    execution: Arc<Semaphore>,
    publication: Arc<Semaphore>,
    observation: Arc<Semaphore>,
    #[cfg(test)]
    provider_idle: Arc<std::sync::Mutex<Vec<weaver_ledger::ParkedProviderConnection>>>,
}
impl Admission {
    pub(crate) fn new(execution: usize) -> Self {
        Self {
            execution: Arc::new(Semaphore::new(execution)),
            publication: Arc::new(Semaphore::new(1)),
            observation: Arc::new(Semaphore::new(2)),
            #[cfg(test)]
            provider_idle: Arc::new(std::sync::Mutex::new(Vec::new())),
        }
    }
    pub(crate) fn execution(&self) -> Result<Arc<OwnedSemaphorePermit>, Status> {
        acquire(&self.execution)
    }
    pub(crate) async fn session_execution(&self) -> Option<Arc<OwnedSemaphorePermit>> {
        self.execution
            .clone()
            .acquire_owned()
            .await
            .ok()
            .map(Arc::new)
    }
    pub(crate) fn publication(&self) -> Result<Arc<OwnedSemaphorePermit>, Status> {
        acquire(&self.publication)
    }
    pub(crate) fn observation(&self) -> Result<Arc<OwnedSemaphorePermit>, Status> {
        acquire(&self.observation)
    }

    /// Called once by a tracked provider worker holding its execution permit.
    /// A new connection is created only when the idle set is empty.
    #[cfg(test)]
    pub(crate) fn checkout_provider(
        &self,
        path: &std::path::Path,
        shutdown: &tokio_util::sync::CancellationToken,
    ) -> weaver_contracts::Result<(weaver_ledger::Ledger, bool)> {
        let parked = {
            let mut idle = self
                .provider_idle
                .lock()
                .map_err(|_| weaver_contracts::Error::Conflict("provider custody poisoned"))?;
            if shutdown.is_cancelled() {
                return Err(weaver_contracts::Error::Conflict("provider custody closed"));
            }
            idle.pop()
        };
        match parked {
            Some(parked) => parked.checkout().map(|ledger| (ledger, true)),
            None => weaver_ledger::Ledger::open(path).map(|ledger| (ledger, false)),
        }
    }

    /// Return before releasing the execution permit. Failed workers drop their
    /// ledger in the worker instead. Idle custody ends with the tracked owner.
    #[cfg(test)]
    pub(crate) fn park_provider(
        &self,
        ledger: weaver_ledger::Ledger,
        shutdown: &tokio_util::sync::CancellationToken,
    ) {
        if let Ok(parked) = ledger.park_provider_connection()
            && let Ok(mut idle) = self.provider_idle.lock()
            && !shutdown.is_cancelled()
        {
            idle.push(parked);
        }
    }
}
fn acquire(lane: &Arc<Semaphore>) -> Result<Arc<OwnedSemaphorePermit>, Status> {
    lane.clone()
        .try_acquire_owned()
        .map(Arc::new)
        .map_err(|_| Status::resource_exhausted("native lane full"))
}

#[cfg(test)]
#[path = "../tests/unit/admission.rs"]
mod tests;
