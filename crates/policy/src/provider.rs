//! Cache immutable source facts, never authorization decisions or mutable authority.
use weaver_contracts::{Error, ProviderPlan, ProviderRoute, Result, Task, body_digest};

/// Small immutable projection made only after validating the original task and plan.
pub struct BoundProviderPolicy {
    principal: String,
    target: String,
    context: serde_json::Value,
}
/// Current effect coordinates supplied by the deciding owner, not the RPC caller.
pub struct ProviderCheck<'a> {
    pub action: &'static str,
    pub sequence: u64,
    pub format: &'a str,
}
/// Validate the source commitment once before constructing cached immutable facts.
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
        principal: task.principal.clone(),
        target: route.target.clone(),
        context: serde_json::json!({
            "family":plan.family,"node":plan.node,"profile":plan.profile,"model":plan.model,
            "endpoint":route.endpoint,"body_digest":body_digest(&plan.body),"plan_digest":plan.digest()?,
            "ceiling":plan.ceiling,"revision":plan.revision,"fence":plan.fence
            ,"profile_digest":plan.profile_commitment,"protocol":task.provider_profile.as_ref().ok_or(Error::Denied)?.protocol,
            "output_token_limit":facts.output_token_limit,"message_count":facts.message_count
        }),
    })
}
impl BoundProviderPolicy {
    /// Evaluate fresh Policy for each effect; cached facts cannot provide an allow decision.
    pub fn authorize(&self, source: &str, check: ProviderCheck<'_>) -> Result<()> {
        let mut context = self.context.clone();
        context["sequence"] = serde_json::json!(check.sequence);
        context["format"] = serde_json::json!(check.format);
        crate::authorize::evaluate(source, &self.principal, &self.target, check.action, context)
    }
}
