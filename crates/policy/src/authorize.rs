// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Error-free Cedar evaluation over authoritative task and wire facts.
use cedar_policy::{Authorizer, Context, Decision, Entities, EntityUid, Request};
use weaver_contracts::{Error, Proposal, Result, Task};

/// Reject malformed contracts before admission.
pub fn validate(source: &str) -> Result<()> {
    crate::compiled::with_policy(source, |_| ())
}
/// Require an error-free allow decision for the actual operation.
pub fn authorize(source: &str, task: &Task, proposal: &Proposal) -> Result<()> {
    let context = serde_json::json!({
        "family":task.family,"node":proposal.node,"profile":task.profile,
        "model":proposal.model,"endpoint":proposal.endpoint,"wire_digest":proposal.digest()?,
        "ceiling":proposal.ceiling,"revision":proposal.revision,"fence":proposal.fence
    });
    evaluate(source, &task.principal, &proposal.target, "invoke", context)
}
/// Preserve Cedar identity parsing semantics; bound provider subjects parse once.
pub(crate) fn entity(kind: &str, id: &str) -> Result<EntityUid> {
    format!("Weaver::{kind}::{}", serde_json::to_string(id)?)
        .parse()
        .map_err(|_| Error::Invalid("entity identity"))
}
pub(crate) fn evaluate(
    source: &str,
    principal: &str,
    target: &str,
    action: &str,
    context: serde_json::Value,
) -> Result<()> {
    let context = Context::from_json_value(context, None)
        .map_err(|_| Error::Policy("invalid authoritative context".into()))?;
    evaluate_typed(
        source,
        entity("Principal", principal)?,
        entity("Target", target)?,
        action,
        context,
    )
}
pub(crate) fn evaluate_typed(
    source: &str,
    principal: EntityUid,
    target: EntityUid,
    action: &str,
    context: Context,
) -> Result<()> {
    let request = Request::new(principal, entity("Action", action)?, target, context, None)
        .map_err(|_| Error::Policy("invalid request".into()))?;
    let response = crate::compiled::with_policy(source, |policies| {
        Authorizer::new().is_authorized(&request, policies, &Entities::empty())
    })?;
    // Require error-free evaluation, including errors in unrelated policies.
    if response.decision() != Decision::Allow || response.diagnostics().errors().next().is_some() {
        return Err(Error::Denied);
    }
    Ok(())
}
