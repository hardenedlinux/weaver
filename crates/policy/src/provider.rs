// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Retain immutable source facts, never decisions or mutable authority.
use crate::{authorize, provider_context::ProviderContext};
use cedar_policy::EntityUid;
use weaver_contracts::{Error, ProviderPlan, ProviderRoute, Result, Task};

/// Typed immutable source projection; each use still evaluates current Policy.
pub struct BoundProviderPolicy {
    principal: EntityUid,
    target: EntityUid,
    context: ProviderContext,
}
/// Current effect coordinates supplied by the deciding owner, not the RPC caller.
pub struct ProviderCheck<'a> {
    pub action: &'static str,
    pub sequence: u64,
    pub format: &'a str,
    pub domains: Option<&'a weaver_contracts::DomainView>,
}
/// Validate the original commitment once before constructing inert Cedar literals.
pub fn bind_provider(
    task: &Task,
    plan: &ProviderPlan,
    route: &ProviderRoute,
) -> Result<BoundProviderPolicy> {
    let facts = plan.binding(task)?.ok_or(Error::Denied)?;
    if !plan.routes.contains(route) {
        return Err(Error::Denied);
    }
    Ok(BoundProviderPolicy {
        principal: authorize::entity("Principal", &task.principal)?,
        target: authorize::entity("Target", &route.target)?,
        context: ProviderContext::capture(task, plan, route, &facts)?,
    })
}
impl BoundProviderPolicy {
    /// No current Policy, domains, action, sequence or format survives this call.
    pub fn authorize(&self, source: &str, check: ProviderCheck<'_>) -> Result<()> {
        authorize::evaluate_typed(
            source,
            self.principal.clone(),
            self.target.clone(),
            check.action,
            self.context.current(&check)?,
        )
    }
}
