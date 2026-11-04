// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Deterministic benchmark source fixture; no external provider or credential.
use weaver_contracts::{ProviderPlan, ProviderRoute, Task, body_digest};
pub fn task_plan(bytes: usize, endpoint: &str) -> (Task, ProviderPlan) {
    let profile: weaver_contracts::ProviderProfile = weaver_contracts::decode(include_bytes!(
        "../../../../prod/policies/provider/profile.json"
    ))
    .expect("source profile");
    let body = format!(
        r#"{{"model":"model-a","stream":true,"messages":[{{"role":"user","content":"{}"}}],"max_completion_tokens":32}}"#,
        "x".repeat(bytes)
    );
    let plan = ProviderPlan {
        family: "f".into(),
        node: "infer".into(),
        profile: "p".into(),
        profile_commitment: profile.digest().expect("profile commitment"),
        model: "model-a".into(),
        body,
        routes: vec![ProviderRoute {
            target: "primary".into(),
            endpoint: endpoint.into(),
        }],
        ceiling: 4,
        revision: 0,
        fence: 1,
    };
    let task = Task {
        provider_profile: Some(profile),
        family: "f".into(),
        principal: "alice".into(),
        profile: "p".into(),
        nodes: vec!["infer".into()],
        targets: vec!["primary".into()],
        endpoints: [("primary".into(), endpoint.into())].into(),
        body_digests: [("infer".into(), body_digest(&plan.body))].into(),
        node_cost_bounds: [("infer".into(), 4)].into(),
        stream_contracts: [("infer".into(), plan.digest().expect("benchmark commitment"))].into(),
        models: vec!["model-a".into()],
        budget: 8,
    };
    (task, plan)
}
