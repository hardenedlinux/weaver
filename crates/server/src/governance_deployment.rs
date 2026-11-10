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

pub(crate) fn load_catalog() -> Result<Option<Vec<u8>>> {
    let Some(path) = std::env::var_os("WEAVER_GOVERNANCE_CATALOG") else {
        return Ok(None);
    };
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| Error::Invalid("governance catalog file"))?
        .take((weaver_contracts::MAX_BODY_BYTES * 2 + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| Error::Invalid("governance catalog read"))?;
    Ok(Some(bytes))
}

pub(crate) async fn start(
    runtime: &ServiceRuntime,
    configuration: Option<Vec<u8>>,
) -> Result<Option<crate::GovernanceWorker>> {
    let retire = match std::env::var("WEAVER_GOVERNANCE_RETIRE_ON_ACTIVATION") {
        Ok(value) if value == "1" => true,
        Err(std::env::VarError::NotPresent) => false,
        _ => return Err(Error::Invalid("single-provider lifecycle setting")),
    };
    let Some(configuration) = configuration else {
        if retire || runtime.fact_feed().is_some() {
            return Err(Error::Invalid("linked Scheme owner requires a catalog"));
        }
        #[cfg(feature = "scheme-program")]
        {
            let capacity = std::thread::available_parallelism()
                .map_err(|_| Error::Invalid("host compiler budget"))?;
            return start_compiler(runtime, None, capacity)
                .await
                .map(|(worker, _)| Some(worker));
        }
        #[cfg(not(feature = "scheme-program"))]
        return Ok(None);
    };
    #[cfg(not(feature = "scheme-program"))]
    let catalog: ProducerCatalog = ProducerCatalog::from_configuration(&configuration)
        .map_err(|_| Error::Invalid("compiled Scheme program feature required"))?;
    #[cfg(feature = "scheme-program")]
    let (worker, catalog) = {
        let capacity = std::thread::available_parallelism()
            .map_err(|_| Error::Invalid("host compiler budget"))?;
        {
            let (worker, catalog) = start_compiler(runtime, Some(configuration), capacity).await?;
            (
                worker,
                catalog.ok_or(Error::Invalid("prepared catalog missing"))?,
            )
        }
    };
    let session_workflow = runtime
        .fact_feed()
        .filter(|feed| !feed.workflow_path.is_empty());
    let session_original = catalog.has_session_workflow().then_some(&catalog);
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
        && (!retire || !catalog.admits_workflow(&feed.family, edge))
    {
        return Err(Error::Invalid(
            "workflow requires the single compiled provider original",
        ));
    }
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
        worker.publish_producers(catalog)?;
        Ok(Some(worker))
    }
}
#[cfg(feature = "scheme-program")]
async fn start_compiler(
    runtime: &ServiceRuntime,
    configuration: Option<Vec<u8>>,
    capacity: NonZeroUsize,
) -> Result<(crate::GovernanceWorker, Option<ProducerCatalog>)> {
    let slots = Arc::new(tokio::sync::Semaphore::new(capacity.get()));
    let slot = Arc::new(
        slots
            .try_acquire_owned()
            .map_err(|_| Error::Conflict("compiler owner budget"))?,
    );
    let (prepared, receive) = tokio::sync::oneshot::channel();
    let worker = runtime
        .start_governance_with_governor(
            slot,
            capacity,
            move || {
                let mut compiler = weaver_governance::SchemeCompiler::initialize()
                    .map_err(|_| Error::Conflict("approved Scheme program unavailable"))?;
                let catalog = configuration
                    .as_ref()
                    .map(|configuration| {
                        ProducerCatalog::from_configuration_with(configuration, |input| {
                            crate::source_composition::compose_catalog(&mut compiler, input)
                        })
                        .map_err(|_| Error::Invalid("governance catalog configuration"))
                    })
                    .transpose()?;
                prepared
                    .send(catalog)
                    .map_err(|_| Error::Conflict("catalog preparation cancelled"))?;
                Ok(compiler)
            },
            weaver_governance::SchemeCompiler::compile_cancellable,
            weaver_governance::SchemeCompiler::evaluate,
        )
        .await?;
    let catalog = receive
        .await
        .map_err(|_| Error::Conflict("catalog preparation unavailable"))?;
    Ok((worker, catalog))
}
