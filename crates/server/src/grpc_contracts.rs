// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed Protobuf/domain mapping. These values never grant execution authority.
use crate::pb;
use tonic::Status;
use weaver_contracts::{Error, ProviderPlan, ProviderRoute, Task};

pub(crate) fn compilation_status(error: weaver_governance::CatalogError) -> Status {
    use weaver_governance::{CatalogError, SourceJobError};
    match error {
        CatalogError::Denied => Status::permission_denied("producer/source binding rejected"),
        CatalogError::Invalid => Status::failed_precondition("producer catalog invalid"),
        CatalogError::Schedule(SourceJobError::Busy) => {
            Status::resource_exhausted("source compilation lane full")
        }
        CatalogError::Schedule(SourceJobError::Source(_)) => {
            Status::failed_precondition("source compiler rejected original")
        }
        CatalogError::Schedule(_) => Status::unavailable("source compiler unavailable"),
    }
}
pub(crate) fn publication_receipt(
    receipt: weaver_contracts::PublicationReceipt,
) -> pb::PublicationReceipt {
    pb::PublicationReceipt {
        operation_id: receipt.operation_id,
        digest: receipt.digest,
        outcome: match receipt.outcome {
            weaver_contracts::PublicationOutcome::Committed => {
                pb::PublicationOutcome::Committed as i32
            }
            weaver_contracts::PublicationOutcome::Rejected => {
                pb::PublicationOutcome::Rejected as i32
            }
        },
        revision: receipt.revision,
        fence: receipt.fence,
    }
}
pub(crate) fn status(_: Error) -> Status {
    Status::failed_precondition("native authority or state rejected")
}
pub(crate) fn plan(p: pb::ProviderPlan) -> std::result::Result<ProviderPlan, Status> {
    let body = String::from_utf8(p.body)
        .map_err(|_| Status::invalid_argument("UTF-8 provider body required"))?;
    let plan = ProviderPlan {
        family: p.family,
        node: p.node,
        profile: p.profile,
        profile_commitment: p.profile_commitment,
        model: p.model,
        body,
        routes: p
            .routes
            .into_iter()
            .map(|r| ProviderRoute {
                target: r.target,
                endpoint: r.endpoint,
            })
            .collect(),
        ceiling: p.ceiling,
        revision: p.revision,
        fence: p.fence,
    };
    plan.validate().map_err(status)?;
    Ok(plan)
}
pub(crate) fn task_contract(t: pb::Task) -> Task {
    Task {
        provider_profile: t
            .provider_profile
            .map(|profile| weaver_contracts::ProviderProfile {
                id: profile.id,
                protocol: profile.protocol,
                max_output_tokens: profile.max_output_tokens,
                max_messages: profile.max_messages,
                max_body_bytes: profile.max_body_bytes,
            }),
        family: t.family,
        principal: t.principal,
        profile: t.profile,
        nodes: t.nodes,
        targets: t.targets,
        endpoints: t.endpoints.into_iter().collect(),
        body_digests: t.body_digests.into_iter().collect(),
        node_cost_bounds: t.node_cost_bounds.into_iter().collect(),
        stream_contracts: t.stream_contracts.into_iter().collect(),
        models: t.models,
        budget: t.budget,
    }
}

pub(crate) fn domain_view(v: weaver_contracts::DomainView) -> pb::DomainView {
    pb::DomainView {
        family: v.family,
        canonical_family: v.canonical_family,
        stamp: Some(pb::DomainStamp {
            task_key: v.stamp.task_key,
            origin: v.stamp.origin,
            budget_root: v.stamp.budget_root,
            history_root: v.stamp.history_root,
            budget_epoch: v.stamp.budget_epoch,
            history_epoch: v.stamp.history_epoch,
        }),
        budget_limit: v.budget_limit,
        held: v.held,
        history_count: v.history_count,
    }
}
