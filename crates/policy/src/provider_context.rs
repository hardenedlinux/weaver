// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Immutable Cedar literals plus freshly supplied effect coordinates.
use crate::ProviderCheck;
use cedar_policy::{Context, RestrictedExpression};
use weaver_contracts::{
    Error, ProviderPlan, ProviderRequestFacts, ProviderRoute, Result, Task, body_digest,
};

type Field = (String, RestrictedExpression);
fn text(key: &str, value: &str) -> Field {
    (key.into(), RestrictedExpression::new_string(value.into()))
}
fn number(key: &str, value: u64) -> Result<Field> {
    let value =
        i64::try_from(value).map_err(|_| Error::Policy("invalid authoritative context".into()))?;
    Ok((key.into(), RestrictedExpression::new_long(value)))
}
pub(crate) struct ProviderContext {
    fields: Vec<Field>,
}
impl ProviderContext {
    pub(crate) fn capture(
        task: &Task,
        plan: &ProviderPlan,
        route: &ProviderRoute,
        facts: &ProviderRequestFacts,
    ) -> Result<Self> {
        let mut fields = vec![
            text("family", &plan.family),
            text("node", &plan.node),
            text("profile", &plan.profile),
            text("model", &plan.model),
            text("endpoint", &route.endpoint),
            text("body_digest", &body_digest(&plan.body)),
            text("plan_digest", &plan.digest()?),
            text("profile_digest", &plan.profile_commitment),
            text(
                "protocol",
                &task
                    .provider_profile
                    .as_ref()
                    .ok_or(Error::Denied)?
                    .protocol,
            ),
        ];
        for (key, value) in [
            ("ceiling", plan.ceiling),
            ("revision", plan.revision),
            ("fence", plan.fence),
            ("output_token_limit", facts.output_token_limit),
            ("message_count", facts.message_count),
        ] {
            fields.push(number(key, value)?);
        }
        Ok(Self { fields })
    }
    pub(crate) fn current(&self, check: &ProviderCheck<'_>) -> Result<Context> {
        let extra = if check.domains.is_some() { 11 } else { 2 };
        let mut fields = Vec::with_capacity(self.fields.len() + extra);
        fields.extend(self.fields.iter().cloned());
        fields.push(number("sequence", check.sequence)?);
        fields.push(text("format", check.format));
        if let Some(domains) = check.domains {
            for (key, value) in [
                ("task_key", &domains.stamp.task_key),
                ("origin", &domains.stamp.origin),
                ("budget_domain", &domains.stamp.budget_root),
                ("history_domain", &domains.stamp.history_root),
            ] {
                fields.push(text(key, value));
            }
            for (key, value) in [
                ("budget_epoch", domains.stamp.budget_epoch),
                ("history_epoch", domains.stamp.history_epoch),
                ("shared_held", domains.held),
                ("shared_limit", domains.budget_limit),
                ("history_count", domains.history_count),
            ] {
                fields.push(number(key, value)?);
            }
        }
        Context::from_pairs(fields)
            .map_err(|_| Error::Policy("invalid authoritative context".into()))
    }
}
