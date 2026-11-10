// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{ProducerCatalog, source_fixture};
use proptest::{arbitrary::any, prop_assert_eq, proptest};
use serde_json::json;
fn configuration(name: &str, epoch: u64) -> serde_json::Value {
    let source = source_fixture::source();
    json!({"producers":[{"name":name,"authority":{"epoch":epoch,"identity":{"certificate_sha256":"1".repeat(64),"public_key_sha256":"2".repeat(64),"credential_sha256":"3".repeat(64)}},
    "original":{"governance":{"schema":source.governance.schema,"family":source.governance.family,"open_nodes":source.governance.open_nodes},"tasks":source.tasks,"plans":source.plans,"publication":source.publication}}]})
}
proptest! {
    #[test]
    fn configuration_cannot_alias_one_family(name in "[a-z]{1,32}", epoch in 0u64..=weaver_contracts::MAX_CREDITS, duplicate in any::<bool>()) {
        let mut data = configuration(&name,epoch);
        if duplicate {
            let mut alias=data["producers"][0].clone();
            alias["name"]=json!(format!("{name}-alias"));
            data["producers"].as_array_mut().expect("array").push(alias);
        }
        let bytes=serde_json::to_vec(&data).expect("data");
        prop_assert_eq!(ProducerCatalog::from_configuration(&bytes).is_ok(),!duplicate);
    }
}
#[test]
fn configuration_rejects_duplicate_keys_code_and_source_substitution_fields() {
    let data = configuration("approved", 0);
    let rows = &data["producers"];
    let duplicate = format!("{{\"producers\":{rows},\"producers\":{rows}}}");
    assert!(ProducerCatalog::from_configuration(duplicate.as_bytes()).is_err());
    for field in ["module", "source", "callback", "authority_override"] {
        let mut changed = data.clone();
        changed[field] = json!("untrusted");
        assert!(
            ProducerCatalog::from_configuration(&serde_json::to_vec(&changed).expect("data"))
                .is_err()
        );
    }
    assert!(ProducerCatalog::from_configuration(br#"{"producers":[]}"#).is_err());
}

#[test]
fn composition_requires_one_source_form_and_the_trusted_startup_owner() {
    let mut data = configuration("approved", 0);
    let original = data["producers"][0]
        .as_object_mut()
        .expect("binding")
        .remove("original")
        .expect("original");
    let mut raw = original.clone();
    raw["tasks"][0]["body_digests"] = json!({});
    raw["tasks"][0]["stream_contracts"] = json!({});
    raw["plans"] = json!([]);
    let routing: Vec<_> = original["plans"].as_array().expect("plans").iter().map(|plan|
        json!({"node":plan["node"],"allowed_modules":["approved"],"required":[],"max_latency_ms":100,"max_procurement_cost":4,"user_token_rates":[0,0,0,0],
            "candidates":[{"module":"approved","capabilities":[],"latency_ms":10,"procurement_rates":[0,0,0,0],"token_bounds":[0,0,0,32],"plan":plan}]})).collect();
    data["producers"][0]["composition"] = json!({"source": raw, "routing": routing});
    let bytes = serde_json::to_vec(&data).expect("configuration");
    assert!(ProducerCatalog::from_configuration(&bytes).is_err());
    let mut calls = 0;
    assert!(
        ProducerCatalog::from_configuration_with(&bytes, |_| {
            calls += 1;
            crate::OwnedSource::from_source(source_fixture::source())
        })
        .is_ok()
    );
    assert_eq!(calls, 1);
    data["producers"][0]["original"] = data["producers"][0]["composition"]["source"].clone();
    assert!(
        ProducerCatalog::from_configuration_with(
            &serde_json::to_vec(&data).expect("configuration"),
            |_| { panic!("ambiguous source entered composition") }
        )
        .is_err()
    );
}

#[test]
fn source_composition_cannot_seal_a_self_consistent_scope_substitution() {
    let original = source_fixture::source();
    let mut raw = original.clone();
    raw.plans.clear();
    raw.tasks[0].body_digests.clear();
    raw.tasks[0].stream_contracts.clear();
    let composition = crate::SourceComposition {
        source: raw,
        routing: original
            .plans
            .iter()
            .map(|plan| crate::RoutingSelection {
                node: plan.node.clone(),
                allowed_modules: vec!["approved".into()],
                required: vec![],
                max_latency_ms: 100,
                max_procurement_cost: 4,
                user_token_rates: [0; 4],
                candidates: vec![crate::RoutingCandidate {
                    module: "approved".into(),
                    capabilities: vec![],
                    latency_ms: 10,
                    procurement_rates: [0; 4],
                    token_bounds: [0, 0, 0, 32],
                    plan: plan.clone(),
                }],
            })
            .collect(),
    };
    for field in 0..5 {
        let mut candidate = original.clone();
        match field {
            0 => candidate.tasks[0].principal = "other".into(),
            1 => candidate.tasks[0].budget += 1,
            2 => candidate.publication.policy = "permit(principal,action,resource);".into(),
            3 => {
                candidate.plans[0].body = candidate.plans[0].body.replace("xxxxxxxx", "zzzzzzzz");
                candidate.tasks[0].body_digests.insert(
                    candidate.plans[0].node.clone(),
                    weaver_contracts::body_digest(&candidate.plans[0].body),
                );
                candidate.tasks[0].stream_contracts.insert(
                    candidate.plans[0].node.clone(),
                    candidate.plans[0].digest().expect("self consistent plan"),
                );
            }
            _ => candidate.governance.open_nodes.reverse(),
        }
        let candidate =
            crate::OwnedSource::from_source(candidate).expect("self consistent candidate");
        assert!(
            composition.validate_selected(&candidate).is_err(),
            "field {field}"
        );
    }
}
