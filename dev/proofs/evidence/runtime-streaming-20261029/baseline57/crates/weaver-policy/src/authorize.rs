//! Error-free Cedar evaluation over authoritative task and wire facts.
use cedar_policy::{Authorizer, Context, Decision, Entities, EntityUid, PolicySet, Request};
use weaver_contracts::{Error, Proposal, Result, Task};

/// Reject malformed contracts before admission.
pub fn validate(source: &str) -> Result<()> {
    source
        .parse::<PolicySet>()
        .map_err(|_| Error::Policy("invalid policy set".into()))?;
    Ok(())
}

/// Require an error-free allow decision for the actual operation.
pub fn authorize(source: &str, task: &Task, proposal: &Proposal) -> Result<()> {
    let policies: PolicySet = source
        .parse()
        .map_err(|_| Error::Policy("invalid policy set".into()))?;
    let uid = |kind: &str, id: &str| -> Result<EntityUid> {
        format!("Weaver::{kind}::{}", serde_json::to_string(id)?)
            .parse()
            .map_err(|_| Error::Invalid("entity identity"))
    };
    let context = Context::from_json_value(
        serde_json::json!({
            "family":task.family,"node":proposal.node,"profile":task.profile,
            "model":proposal.model,"endpoint":proposal.endpoint,"wire_digest":proposal.digest()?,
            "ceiling":proposal.ceiling,"revision":proposal.revision,"fence":proposal.fence
        }),
        None,
    )
    .map_err(|_| Error::Policy("invalid authoritative context".into()))?;
    let request = Request::new(
        uid("Principal", &task.principal)?,
        uid("Action", "invoke")?,
        uid("Target", &proposal.target)?,
        context,
        None,
    )
    .map_err(|_| Error::Policy("invalid request".into()))?;
    let response = Authorizer::new().is_authorized(&request, &policies, &Entities::empty());
    // Cedar's default can ignore errors in unrelated policies. This host requires error-free evaluation.
    if response.decision() != Decision::Allow || response.diagnostics().errors().next().is_some() {
        return Err(Error::Denied);
    }
    Ok(())
}
