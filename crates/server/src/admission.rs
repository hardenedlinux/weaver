// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Separate bounded native lanes keep execution saturation out of authority publication.
use std::sync::Arc;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tonic::Status;

#[derive(Clone)]
pub(crate) struct Admission {
    execution: Arc<Semaphore>,
    publication: Arc<Semaphore>,
    observation: Arc<Semaphore>,
}
impl Admission {
    pub(crate) fn new(execution: usize) -> Self {
        Self {
            execution: Arc::new(Semaphore::new(execution)),
            publication: Arc::new(Semaphore::new(1)),
            observation: Arc::new(Semaphore::new(2)),
        }
    }
    pub(crate) fn execution(&self) -> Result<Arc<OwnedSemaphorePermit>, Status> {
        acquire(&self.execution)
    }
    pub(crate) fn publication(&self) -> Result<Arc<OwnedSemaphorePermit>, Status> {
        acquire(&self.publication)
    }
    pub(crate) fn observation(&self) -> Result<Arc<OwnedSemaphorePermit>, Status> {
        acquire(&self.observation)
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
