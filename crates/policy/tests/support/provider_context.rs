// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Independent original JSON context oracle; test/benchmark only, never a cache.
use crate::ProviderCheck;
use cedar_policy::Context;
use weaver_contracts::{ProviderPlan, ProviderRoute, Task, body_digest};

pub struct JsonContext(serde_json::Value);
impl JsonContext {
    pub fn capture(task: &Task, plan: &ProviderPlan, route: &ProviderRoute) -> Self {
        let facts = plan.binding(task).expect("binding").expect("profile");
        Self(serde_json::json!({
            "family":plan.family,"node":plan.node,"profile":plan.profile,"model":plan.model,
            "endpoint":route.endpoint,"body_digest":body_digest(&plan.body),"plan_digest":plan.digest().expect("digest"),
            "ceiling":plan.ceiling,"revision":plan.revision,"fence":plan.fence,
            "profile_digest":plan.profile_commitment,"protocol":task.provider_profile.as_ref().expect("profile").protocol,
            "output_token_limit":facts.output_token_limit,"message_count":facts.message_count
        }))
    }
    pub fn current(&self, check: &ProviderCheck<'_>) -> weaver_contracts::Result<Context> {
        let mut value = self.0.clone();
        value["sequence"] = serde_json::json!(check.sequence);
        value["format"] = serde_json::json!(check.format);
        if let Some(d) = check.domains {
            value["task_key"] = serde_json::json!(d.stamp.task_key);
            value["origin"] = serde_json::json!(d.stamp.origin);
            value["budget_domain"] = serde_json::json!(d.stamp.budget_root);
            value["history_domain"] = serde_json::json!(d.stamp.history_root);
            value["budget_epoch"] = serde_json::json!(d.stamp.budget_epoch);
            value["history_epoch"] = serde_json::json!(d.stamp.history_epoch);
            value["shared_held"] = serde_json::json!(d.held);
            value["shared_limit"] = serde_json::json!(d.budget_limit);
            value["history_count"] = serde_json::json!(d.history_count);
        }
        Context::from_json_value(value, None)
            .map_err(|_| weaver_contracts::Error::Policy("invalid authoritative context".into()))
    }
}
