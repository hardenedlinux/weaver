// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Rejoin the same SQL lane after one compact advisory call to the Scheme owner.
use super::{SourceOwner, command::Envelope};
use crate::runtime::RuntimeOwner;
use tonic::Status;
use weaver_contracts::{ProviderPlan, ProviderRoute, ProviderTurnDerivation};

impl SourceOwner {
    pub(super) async fn admit_turn(
        &self,
        runtime: &RuntimeOwner,
        request: weaver_ledger::ProviderSessionRequest,
    ) -> Result<ProviderTurnDerivation, Status> {
        let cut = self
            .internal(|reply, slot| Envelope::SessionCut {
                request,
                reply,
                slot,
            })
            .await?;
        if let Some(derived) = cut.retained_derivation().cloned() {
            if runtime.closing() {
                return Err(Status::unavailable("Session recovery closed"));
            }
            return self
                .internal(|reply, slot| Envelope::SessionTurn {
                    observed: Box::new(cut),
                    derived: Box::new(derived),
                    reply,
                    slot,
                })
                .await;
        }
        let facts = cut
            .scope()
            .request_facts(&cut.request().principal, &cut.request().submission)
            .map_err(crate::grpc_contracts::status)?;
        let input = weaver_governance::SessionTurnInput {
            scope: cut.scope().clone(),
            facts: weaver_governance::SessionTurnFacts {
                principal: cut.request().principal.clone(),
                model: facts.model,
                output_token_limit: facts.output_token_limit,
                message_count: facts.message_count,
                body_bytes: cut.request().submission.body.len() as u64,
            },
        };
        let selected = runtime
            .governor()
            .map_err(crate::grpc_contracts::status)?
            .session_turn(input)
            .await
            .map_err(crate::grpc_contracts::source_job_status)?;
        if runtime.closing() {
            return Err(Status::unavailable("Session derivation closed"));
        }
        let derived = project(&cut, selected)?;
        self.internal(|reply, slot| Envelope::SessionTurn {
            observed: Box::new(cut),
            derived: Box::new(derived),
            reply,
            slot,
        })
        .await
    }
}

// Canonical data projection only: route decisions belong to the Scheme result;
// request interpretation, commitments and final admission stay independently checked.
fn project(
    cut: &weaver_ledger::ProviderSessionCut,
    selected: weaver_governance::SessionTurnSelection,
) -> Result<ProviderTurnDerivation, Status> {
    let scope = cut.scope();
    let request = cut.request();
    if selected.scope_commitment != scope.digest().map_err(crate::grpc_contracts::status)? {
        return Err(Status::failed_precondition(
            "Session selection scope changed",
        ));
    }
    let mut task = scope.template.clone();
    task.family = scope
        .turn_family(&request.submission)
        .map_err(crate::grpc_contracts::status)?;
    let node = task.nodes[0].clone();
    let routes = selected
        .route_indices
        .into_iter()
        .map(|i| {
            let target = task
                .targets
                .get(i)
                .ok_or(Status::failed_precondition("Session route index"))?;
            let endpoint = task
                .endpoints
                .get(target)
                .ok_or(Status::failed_precondition("Session route endpoint"))?;
            Ok(ProviderRoute {
                target: target.clone(),
                endpoint: endpoint.clone(),
            })
        })
        .collect::<Result<Vec<_>, Status>>()?;
    let facts = scope
        .request_facts(&request.principal, &request.submission)
        .map_err(crate::grpc_contracts::status)?;
    let plan = ProviderPlan {
        family: task.family.clone(),
        node: node.clone(),
        profile: task.profile.clone(),
        profile_commitment: task
            .provider_profile
            .as_ref()
            .ok_or(Status::failed_precondition("Session profile missing"))?
            .digest()
            .map_err(crate::grpc_contracts::status)?,
        model: facts.model,
        body: request.submission.body.clone(),
        routes,
        ceiling: task.node_cost_bounds[&node],
        revision: cut.revision(),
        fence: cut.fence(),
    };
    task.body_digests
        .insert(node.clone(), weaver_contracts::body_digest(&plan.body));
    task.stream_contracts
        .insert(node, plan.digest().map_err(crate::grpc_contracts::status)?);
    let mut domains = scope.domains.clone();
    domains.origin.clone_from(&task.family);
    let derived = ProviderTurnDerivation {
        task,
        plan,
        domains,
    };
    scope
        .admits(&request.principal, &request.submission, &derived)
        .map_err(crate::grpc_contracts::status)?;
    Ok(derived)
}

#[cfg(test)]
#[path = "../../tests/unit/session_admission.rs"]
mod tests;
