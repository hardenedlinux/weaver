// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
    let retire = match std::env::var("WEAVER_GOVERNANCE_RETIRE_ON_ACTIVATION") {
        Ok(value) if value == "1" => true,
        Err(std::env::VarError::NotPresent) => false,
        _ => return Err(Error::Invalid("single-provider lifecycle setting")),
    };
    let session_workflow = runtime
        .fact_feed()
        .filter(|feed| !feed.workflow_path.is_empty());
    let session_original = catalog
        .as_ref()
        .filter(|catalog| catalog.has_session_workflow());
    if !match (session_workflow, session_original) {
        (None, None) => true,
        (Some(feed), Some(catalog)) => {
            (retire || feed.workflow_dag) && catalog.admits_session_workflow(feed)
        }
        _ => false,
    } {
        return Err(Error::Invalid(
            "session workflow requires the exact compiled path",
        ));
    }
    if retire
        && session_workflow.is_none()
        && runtime
            .fact_feed()
            .is_some_and(|feed| feed.workflow.is_none())
    {
        return Err(Error::Invalid(
            "compiler retirement requires a deployment without a hard fact feed",
        ));
    }
    if let Some(feed) = runtime.fact_feed()
        && let Some(edge) = &feed.workflow
        && (!retire
            || !catalog
                .as_ref()
                .is_some_and(|catalog| catalog.admits_workflow(&feed.family, edge)))
    {
        return Err(Error::Invalid(
            "workflow requires the single compiled provider original",
        ));
    }
    let Some(catalog) = catalog else {
        if runtime.fact_feed().is_some() {
            return Err(Error::Invalid(
                "hard fact feed requires the linked Scheme owner",
            ));
        }
        if retire {
            return Err(Error::Invalid(
                "single-provider lifecycle requires a catalog",
            ));
        }
        return Ok(None);
    };
    #[cfg(not(feature = "scheme-program"))]
    {
        let _ = (runtime, catalog);
        Err(Error::Invalid("compiled Scheme program feature required"))
    }
    #[cfg(feature = "scheme-program")]
    {
        if retire || session_workflow.is_some_and(|feed| feed.workflow_dag) {
            if !catalog.is_single_provider() {
                return Err(Error::Invalid(
                    "single-provider lifecycle requires exactly one producer",
                ));
            }
            runtime.enable_single_provider()?;
        }
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
        .start_governance_with_governor(
            slot,
            capacity,
            || {
                weaver_governance::SchemeCompiler::initialize()
                    .map_err(|_| Error::Conflict("approved Scheme program unavailable"))
            },
            weaver_governance::SchemeCompiler::compile_cancellable,
            weaver_governance::SchemeCompiler::evaluate,
        )
        .await?;
    worker.publish_producers(catalog)?;
    Ok(worker)
}
