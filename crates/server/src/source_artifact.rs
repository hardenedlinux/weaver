//! Concrete protobuf projection of bound source data, never a new execution permit.
use crate::pb;
use weaver_contracts::{ProviderPlan, ProviderProfile, ProviderRoute, Publication, Task};
use weaver_governance::{BoundSource, SourceData, SourceSelection};
pub(crate) fn artifact(bound: &BoundSource) -> pb::SourceArtifact {
    let SourceData {
        governance,
        tasks,
        plans,
        publication,
    } = bound.source().data();
    let SourceSelection {
        schema,
        family,
        open_nodes,
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
