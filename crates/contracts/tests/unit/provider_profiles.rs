// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use proptest::{prop_assert_eq, proptest, test_runner::Config};
use serde::Deserialize;
use std::collections::BTreeMap;
use weaver_contracts::{ProviderProfile, decode};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Case {
    name: String,
    patch: BTreeMap<String, serde_json::Value>,
    #[serde(default)]
    remove: Vec<String>,
    valid: bool,
}
fn profile() -> ProviderProfile {
    decode(include_bytes!(
        "../../../../prod/policies/provider/profile.json"
    ))
    .expect("profile")
}
fn body() -> serde_json::Value {
    serde_json::json!({"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32})
}
#[test]
fn shared_closed_request_corpus_has_the_declared_semantics() {
    let cases: Vec<Case> = decode(include_bytes!(
        "../../../../prod/policies/provider/request-cases.json"
    ))
    .expect("cases");
    for case in cases {
        let mut value = body();
        for key in case.remove {
            value.as_object_mut().expect("object").remove(&key);
        }
        for (key, field) in case.patch {
            value[&key] = field;
        }
        let result = profile().request_facts(&serde_json::to_string(&value).expect("body"));
        assert_eq!(result.is_ok(), case.valid, "{}", case.name);
    }
}
#[test]
fn profile_commitment_covers_every_semantic_limit_and_protocol() {
    let original = profile();
    let mut tokens = original.clone();
    tokens.max_output_tokens -= 1;
    let mut messages = original.clone();
    messages.max_messages -= 1;
    let mut bytes = original.clone();
    bytes.max_body_bytes -= 1;
    let mut identity = original.clone();
    identity.id = "another-profile".into();
    for changed in [tokens, messages, bytes, identity] {
        assert_ne!(
            original.digest().expect("digest"),
            changed.digest().expect("changed")
        );
    }
    let mut unknown = original;
    unknown.protocol = "unregistered-protocol".into();
    assert!(unknown.digest().is_err());
}
proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn source_profile_limits_bound_all_admitted_requests(limit in 1u64..4097, wanted in 0u64..8193,
        message_limit in 1u64..65, count in 0usize..66) {
        let mut source = profile();
        source.max_output_tokens = limit;
        source.max_messages = message_limit;
        let mut value = body();
        value["max_completion_tokens"] = serde_json::json!(wanted);
        value["messages"] = serde_json::json!(vec![serde_json::json!({"role":"user","content":"hello"});count]);
        let result = source.request_facts(&serde_json::to_string(&value).expect("request"));
        prop_assert_eq!(result.is_ok(), wanted > 0 && wanted <= limit && count > 0 && count as u64 <= message_limit);
    }
}
