//! Borrow the embedding service's reactor; this library creates no worker pool.
use std::future::Future;
use tokio::{runtime::Handle, time::Instant};
use weaver_contracts::{Error, Result};
pub(super) struct IoRuntime {
    pub(super) handle: Handle,
}
impl IoRuntime {
    pub(super) fn wait<T>(
        &self,
        deadline: Instant,
        future: impl Future<Output = Result<T>>,
    ) -> Result<T> {
        if Instant::now() >= deadline {
            return Err(Error::Conflict("provider outcome unknown"));
        }
        let _entered = self.handle.enter();
        futures_executor::block_on(tokio::time::timeout_at(deadline, future))
            .map_err(|_| Error::Conflict("provider outcome unknown"))?
    }
}
