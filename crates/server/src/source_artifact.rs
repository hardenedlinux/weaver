// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Concrete protobuf projection of bound source data, never a new execution permit.
use crate::pb;
use weaver_contracts::{ProviderPlan, ProviderProfile, ProviderRoute, Publication, Task};
use weaver_governance::{BoundSource, SourceComposition, SourceData, SourceSelection};
pub(crate) fn artifact(bound: &BoundSource) -> pb::SourceArtifact {
    artifact_data(bound.source().data())
}
pub(crate) fn composition(input: &SourceComposition) -> pb::SourceCompositionRequest {
    pb::SourceCompositionRequest {
        source: Some(artifact_data(&input.source)),
        routing: input
            .routing
            .iter()
            .map(|row| pb::RoutingSelection {
                node: row.node.clone(),
                allowed_modules: row.allowed_modules.clone(),
                required: row.required.clone(),
                max_latency_ms: row.max_latency_ms,
                max_procurement_cost: row.max_procurement_cost,
                user_token_rates: row.user_token_rates.to_vec(),
                candidates: row
                    .candidates
                    .iter()
                    .map(|candidate| pb::RoutingCandidate {
                        module: candidate.module.clone(),
                        capabilities: candidate.capabilities.clone(),
                        latency_ms: candidate.latency_ms,
                        procurement_rates: candidate.procurement_rates.to_vec(),
                        token_bounds: candidate.token_bounds.to_vec(),
                        plan: Some(plan(&candidate.plan)),
                    })
                    .collect(),
            })
            .collect(),
        ..Default::default()
    }
}
/// Typed projection only; the caller retains source provenance and authority checks.
pub(crate) fn artifact_data(data: &SourceData) -> pb::SourceArtifact {
    let SourceData {
        governance,
        tasks,
        plans,
        publication,
    } = data;
    let SourceSelection {
        schema,
        family,
        open_nodes,
        workflow_edges,
        workflow_selectors,
    } = governance;
    let Publication {
        operation_id,
        expected_revision,
        fence,
        policy,
        schema: policy_schema,
    } = publication;
    pb::SourceArtifact {
        governance: Some(pb::GovernanceSelection {
            schema: schema.clone(),
            family: family.clone(),
            open_nodes: open_nodes.clone(),
            workflow_selectors: workflow_selectors
                .iter()
                .map(|[selector, left, right]| pb::WorkflowSelector {
                    selector: selector.clone(),
                    left: left.clone(),
                    right: right.clone(),
                })
                .collect(),
            workflow_edges: workflow_edges
                .iter()
                .map(|(dependent, dependency)| pb::WorkflowEdge {
                    dependent: dependent.clone(),
                    dependency: dependency.clone(),
                })
                .collect(),
        }),
        tasks: tasks.iter().map(task).collect(),
        plans: plans.iter().map(plan).collect(),
        publication: Some(pb::PublishRequest {
            operation_id: operation_id.clone(),
            expected_revision: *expected_revision,
            fence: *fence,
            policy: policy.clone(),
            schema: policy_schema.clone(),
        }),
    }
}
fn task(value: &Task) -> pb::Task {
    let Task {
        family,
        principal,
        profile,
        provider_profile,
        nodes,
        targets,
        endpoints,
        body_digests,
        node_cost_bounds,
        stream_contracts,
        models,
        budget,
    } = value;
    pb::Task {
        family: family.clone(),
        principal: principal.clone(),
        profile: profile.clone(),
        provider_profile: provider_profile.as_ref().map(|p| {
            let ProviderProfile {
                id,
                protocol,
                max_output_tokens,
                max_messages,
                max_body_bytes,
            } = p;
            pb::ProviderProfile {
                id: id.clone(),
                protocol: protocol.clone(),
                max_output_tokens: *max_output_tokens,
                max_messages: *max_messages,
                max_body_bytes: *max_body_bytes,
            }
        }),
        nodes: nodes.clone(),
        targets: targets.clone(),
        models: models.clone(),
        budget: *budget,
        endpoints: endpoints.clone().into_iter().collect(),
        body_digests: body_digests.clone().into_iter().collect(),
        stream_contracts: stream_contracts.clone().into_iter().collect(),
        node_cost_bounds: node_cost_bounds.clone().into_iter().collect(),
    }
}
fn plan(value: &ProviderPlan) -> pb::ProviderPlan {
    let ProviderPlan {
        family,
        node,
        profile,
        profile_commitment,
        model,
        body,
        routes,
        ceiling,
        revision,
        fence,
    } = value;
    pb::ProviderPlan {
        family: family.clone(),
        node: node.clone(),
        profile: profile.clone(),
        profile_commitment: profile_commitment.clone(),
        model: model.clone(),
        body: body.as_bytes().to_vec(),
        ceiling: *ceiling,
        revision: *revision,
        fence: *fence,
        routes: routes
            .iter()
            .map(|r| {
                let ProviderRoute { target, endpoint } = r;
                pb::Route {
                    target: target.clone(),
                    endpoint: endpoint.clone(),
                }
            })
            .collect(),
    }
}
