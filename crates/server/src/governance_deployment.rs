// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Explicit startup catalog and compiled application; no runtime source loader.
use crate::ServiceRuntime;
use std::io::Read;
#[cfg(feature = "scheme-program")]
use std::{num::NonZeroUsize, sync::Arc};
use weaver_contracts::{Error, Result};
use weaver_governance::ProducerCatalog;

pub(crate) fn load_catalog() -> Result<Option<ProducerCatalog>> {
    let Some(path) = std::env::var_os("WEAVER_GOVERNANCE_CATALOG") else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| Error::Invalid("governance catalog file"))?
        .take((weaver_contracts::MAX_BODY_BYTES * 2 + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Invalid("governance catalog read"))?;
    ProducerCatalog::from_configuration(&bytes)
        .map(Some)
        .map_err(|_| Error::Invalid("governance catalog configuration"))
}

pub(crate) async fn start(
    runtime: &ServiceRuntime,
    catalog: Option<ProducerCatalog>,
) -> Result<Option<crate::GovernanceWorker>> {
    let Some(catalog) = catalog else {
        return Ok(None);
    };
    #[cfg(not(feature = "scheme-program"))]
    {
        let _ = (runtime, catalog);
        Err(Error::Invalid("compiled Scheme program feature required"))
    }
    #[cfg(feature = "scheme-program")]
    {
        let capacity = std::thread::available_parallelism()
            .map_err(|_| Error::Invalid("host compiler budget"))?;
        start_compiler(runtime, catalog, capacity).await.map(Some)
    }
}
#[cfg(feature = "scheme-program")]
async fn start_compiler(
    runtime: &ServiceRuntime,
    catalog: ProducerCatalog,
    capacity: NonZeroUsize,
) -> Result<crate::GovernanceWorker> {
    let slots = Arc::new(tokio::sync::Semaphore::new(capacity.get()));
    let slot = Arc::new(
        slots
            .try_acquire_owned()
            .map_err(|_| Error::Conflict("compiler owner budget"))?,
    );
    let worker = runtime
        .start_governance(slot, capacity, || {
            let mut compiler = weaver_governance::SchemeCompiler::initialize()
                .map_err(|_| Error::Conflict("approved Scheme program unavailable"))?;
            Ok(move |source: &weaver_governance::OwnedSource| compiler.compile(source))
        })
        .await?;
    worker.publish_producers(catalog)?;
    Ok(worker)
}
