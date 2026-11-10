// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Inert authenticated-source projection; no catalog installation or effect authority.
use crate::{
    grpc_contracts::{compilation_status, plan, plan_data, status, task_contract},
    pb,
    runtime::RuntimeOwner,
};
use tonic::Status;
use weaver_governance::{
    OwnedSource, RoutingCandidate, RoutingSelection, SourceComposition, SourceData, SourceSelection,
};

pub(crate) async fn compose(
    runtime: &RuntimeOwner,
    request: pb::SourceCompositionRequest,
    catalog: Option<&[u8]>,
) -> Result<OwnedSource, Status> {
    let input = decode(request)?;
    let catalog = catalog
        .map(weaver_contracts::decode::<weaver_contracts::ProviderCatalog>)
        .transpose()
        .map_err(status)?;
    compose_typed(runtime, input, catalog.as_ref()).await
}

pub(crate) fn decode(request: pb::SourceCompositionRequest) -> Result<SourceComposition, Status> {
    let wire = request
        .source
        .ok_or_else(|| Status::invalid_argument("source required"))?;
    let governance = wire
        .governance
        .ok_or_else(|| Status::invalid_argument("source selection required"))?;
    let publication = wire
        .publication
        .ok_or_else(|| Status::invalid_argument("source publication required"))?;
    let source = SourceData {
        governance: SourceSelection {
            schema: governance.schema,
            family: governance.family,
            open_nodes: governance.open_nodes,
            workflow_edges: governance
                .workflow_edges
                .into_iter()
                .map(|edge| (edge.dependent, edge.dependency))
                .collect(),
            workflow_selectors: governance
                .workflow_selectors
                .into_iter()
                .map(|choice| [choice.selector, choice.left, choice.right])
                .collect(),
        },
        tasks: wire.tasks.into_iter().map(task_contract).collect(),
        plans: wire.plans.into_iter().map(plan).collect::<Result<_, _>>()?,
        publication: weaver_contracts::Publication {
            operation_id: publication.operation_id,
            expected_revision: publication.expected_revision,
            fence: publication.fence,
            policy: publication.policy,
            schema: publication.schema,
        },
    };
    if request.routing.len() > 64 {
        return Err(Status::resource_exhausted("routing selection bound"));
    }
    let mut routing = Vec::with_capacity(request.routing.len());
    for row in request.routing {
        if row.candidates.is_empty() || row.candidates.len() > 8 {
            return Err(Status::invalid_argument("routing candidate bound"));
        }
        routing.push(RoutingSelection {
            node: row.node,
            allowed_modules: row.allowed_modules,
            required: row.required,
            max_latency_ms: row.max_latency_ms,
            max_procurement_cost: row.max_procurement_cost,
            user_token_rates: rates(row.user_token_rates)?,
            candidates: row
                .candidates
                .into_iter()
                .map(|candidate| {
                    Ok(RoutingCandidate {
                        module: candidate.module,
                        capabilities: candidate.capabilities,
                        latency_ms: candidate.latency_ms,
                        procurement_rates: rates(candidate.procurement_rates)?,
                        token_bounds: rates(candidate.token_bounds)?,
                        plan: plan_data(
                            candidate.plan.ok_or_else(|| {
                                Status::invalid_argument("candidate plan required")
                            })?,
                        )?,
                    })
                })
                .collect::<Result<_, Status>>()?,
        });
    }
    Ok(SourceComposition { source, routing })
}

pub(crate) async fn compose_typed(
    runtime: &RuntimeOwner,
    input: SourceComposition,
    catalog: Option<&weaver_contracts::ProviderCatalog>,
) -> Result<OwnedSource, Status> {
    let SourceComposition {
        source,
        mut routing,
    } = input;
    if routing.is_empty() {
        let source = OwnedSource::from_source(source)
            .map_err(|_| Status::failed_precondition("source projection rejected"))?;
        validate_transport(&source)?;
        return Ok(source);
    }
    if let Some(profile) = source
        .tasks
        .first()
        .and_then(|task| task.provider_profile.as_ref())
    {
        let protocol = profile.adapter().map_err(status)?;
        for row in &mut routing {
            row.candidates.retain(|candidate| {
                candidate.plan.routes.iter().all(|route| {
                    weaver_broker::HttpsTransport::validate_provider_endpoint(
                        &route.endpoint,
                        protocol,
                    )
                    .is_ok()
                })
            });
        }
    }
    if let Some(catalog) = catalog {
        for row in &mut routing {
            let mut tariff = None;
            let mut candidates = Vec::new();
            for mut candidate in row.candidates.drain(..) {
                let Ok(digest) = candidate.plan.digest() else {
                    continue;
                };
                let Some(entry) = catalog.entries.get(&digest) else {
                    continue;
                };
                let current = (entry.user_rates, entry.quote.tenant.clone());
                if tariff.as_ref().is_some_and(|prior| prior != &current) {
                    return Err(Status::failed_precondition(
                        "mixed catalog tariffs for original operation",
                    ));
                }
                tariff = Some(current);
                row.user_token_rates = entry.user_rates;
                candidate.module.clone_from(&entry.module);
                candidate.capabilities.clone_from(&entry.capabilities);
                candidate.latency_ms = entry.latency_millis;
                candidate.procurement_rates = entry.quote.procurement_rates;
                candidate.token_bounds = entry.quote.token_bounds;
                candidates.push(candidate);
            }
            row.candidates = candidates;
        }
    }
    let source = runtime
        .governor()
        .map_err(status)?
        .compose(SourceComposition { source, routing })
        .await
        .map_err(|error| compilation_status(weaver_governance::CatalogError::Schedule(error)))?;
    validate_transport(&source)?;
    Ok(source)
}
fn rates(values: Vec<u64>) -> Result<[u64; 4], Status> {
    values
        .try_into()
        .map_err(|_| Status::invalid_argument("four metering categories required"))
}

pub(crate) fn validate_transport(source: &OwnedSource) -> Result<(), Status> {
    let protocol = source
        .task()
        .provider_profile
        .as_ref()
        .ok_or_else(|| Status::failed_precondition("provider profile required"))?
        .adapter()
        .map_err(status)?;
    for plan in source.plans() {
        for route in &plan.routes {
            weaver_broker::HttpsTransport::validate_provider_endpoint(&route.endpoint, protocol)
                .map_err(status)?;
        }
    }
    Ok(())
}

/// Startup uses the same transport eligibility guard as source RPC composition.
#[cfg(feature = "scheme-program")]
pub(crate) fn compose_catalog(
    compiler: &mut weaver_governance::SchemeCompiler,
    configuration: &SourceComposition,
) -> Result<OwnedSource, weaver_governance::SourceError> {
    let mut configuration = configuration.clone();
    let profile = configuration
        .source
        .tasks
        .first()
        .and_then(|task| task.provider_profile.as_ref())
        .ok_or(weaver_governance::SourceError::Contract)?;
    let protocol = profile
        .adapter()
        .map_err(|_| weaver_governance::SourceError::Contract)?;
    for row in &mut configuration.routing {
        row.candidates.retain(|candidate| {
            candidate.plan.routes.iter().all(|route| {
                weaver_broker::HttpsTransport::validate_provider_endpoint(&route.endpoint, protocol)
                    .is_ok()
            })
        });
    }
    let source = compiler.compose(&configuration)?;
    validate_transport(&source).map_err(|_| weaver_governance::SourceError::Contract)?;
    Ok(source)
}
