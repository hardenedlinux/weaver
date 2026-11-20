// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use weaver_contracts::{
    ProviderPlan, ProviderRoute, ProviderSessionScope, ProviderTurnDerivation,
    ProviderTurnSubmission, body_digest, decode,
};

fn scope() -> ProviderSessionScope {
    decode(serde_json::json!({
        "template": {
            "family":"session-a", "principal":"alice", "profile":"p",
            "provider_profile":{"id":"p","protocol":"openai.chat-turn-sse.v1",
                "max_output_tokens":32,"max_messages":8,"max_body_bytes":4096},
            "nodes":["infer"],"targets":["primary"],
            "endpoints":{"primary":"https://provider.invalid/v1/chat/completions"},
            "body_digests":{},"stream_contracts":{},"node_cost_bounds":{"infer":4},
            "models":["model-a"],"budget":8
        },
        "domains":{"origin":"session-a","budget":"shared-budget","history":"shared-history","budget_limit":8},
        "publication":{"operation_id":"source-publication","digest":body_digest("publication")},
        "max_turns":4
    }).to_string().as_bytes()).expect("Session contract fixture")
}

fn submission(key: &str, prompt: &str) -> ProviderTurnSubmission {
    ProviderTurnSubmission {
        operation_id: key.into(),
        body: serde_json::json!({"model":"model-a","stream":true,"messages":[{"role":"user","content":prompt}],"max_tokens":32}).to_string(),
    }
}

fn derived(
    scope: &ProviderSessionScope,
    submission: &ProviderTurnSubmission,
) -> ProviderTurnDerivation {
    let mut task = scope.template.clone();
    task.family = scope
        .turn_family(submission)
        .expect("Session contract fixture");
    let plan = ProviderPlan {
        family: task.family.clone(),
        node: "infer".into(),
        profile: "p".into(),
        profile_commitment: task
            .provider_profile
            .as_ref()
            .expect("Session contract fixture")
            .digest()
            .expect("Session contract fixture"),
        model: "model-a".into(),
        body: submission.body.clone(),
        routes: vec![ProviderRoute {
            target: "primary".into(),
            endpoint: task.endpoints["primary"].clone(),
        }],
        ceiling: 4,
        revision: 1,
        fence: 1,
    };
    task.body_digests
        .insert("infer".into(), body_digest(&submission.body));
    task.stream_contracts.insert(
        "infer".into(),
        plan.digest().expect("Session contract fixture"),
    );
    let mut domains = scope.domains.clone();
    domains.origin.clone_from(&task.family);
    ProviderTurnDerivation {
        task,
        plan,
        domains,
    }
}

#[test]
fn turns_change_bytes_and_origins_but_preserve_source_limits_and_shared_domains() {
    let scope = scope();
    let first = submission("first", "read file");
    let second = submission("second", "file result");
    let a = derived(&scope, &first);
    let b = derived(&scope, &second);
    scope
        .admits("alice", &first, &a)
        .expect("Session contract fixture");
    scope
        .admits("alice", &second, &b)
        .expect("Session contract fixture");
    assert_ne!(a.task.family, b.task.family);
    assert_ne!(
        a.plan.digest().expect("Session contract fixture"),
        b.plan.digest().expect("Session contract fixture")
    );
    assert_eq!(
        (&a.domains.budget, &a.domains.history),
        (&b.domains.budget, &b.domains.history)
    );
    assert_eq!(a.task.budget, b.task.budget);
    assert!(scope.admits("bob", &first, &a).is_err());
}

#[test]
fn concrete_derivation_cannot_change_route_budget_profile_or_bound_body() {
    let scope = scope();
    let input = submission("first", "read file");
    let original = derived(&scope, &input);
    for field in 0..8 {
        let ProviderTurnDerivation {
            mut task,
            mut plan,
            mut domains,
        } = original.clone();
        match field {
            0 => task.principal = "bob".into(),
            1 => task.budget += 1,
            2 => domains.budget = "new-budget".into(),
            3 => domains.history = "new-history".into(),
            4 => {
                plan.routes[0].endpoint = "https://other.invalid/v1/chat/completions".into();
                task.endpoints
                    .insert("primary".into(), plan.routes[0].endpoint.clone());
            }
            5 => plan.ceiling -= 1,
            6 => {
                task.provider_profile
                    .as_mut()
                    .expect("Session contract fixture")
                    .max_messages += 1
            }
            _ => plan.body.push(' '),
        }
        // Refresh every downstream commitment: the source scope must still be
        // decisive even when a malicious derivation is internally consistent.
        task.body_digests
            .insert("infer".into(), body_digest(&plan.body));
        task.stream_contracts.insert(
            "infer".into(),
            plan.digest().expect("Session contract fixture"),
        );
        assert!(
            scope
                .admits(
                    "alice",
                    &input,
                    &ProviderTurnDerivation {
                        task,
                        plan,
                        domains
                    }
                )
                .is_err(),
            "field {field}"
        );
    }
}

#[test]
fn source_scope_is_finite_and_never_accepts_a_prebound_template() {
    for field in 0..5 {
        let mut scope = scope();
        match field {
            0 => scope.max_turns = 0,
            1 => scope.max_turns = 65,
            2 => {
                scope
                    .template
                    .body_digests
                    .insert("infer".into(), body_digest("body"));
            }
            3 => scope.domains.budget_limit += 1,
            _ => scope.domains.origin = "other-session".into(),
        }
        assert!(scope.validate().is_err());
    }
    let scope = scope();
    let input = submission("first", "secret prompt");
    assert!(
        scope.template.validate().is_err(),
        "unbound template cannot register as a Task"
    );
    assert!(!format!("{input:?}").contains("secret prompt"));
    assert!(!format!("{:?}", derived(&scope, &input)).contains("secret prompt"));
    let mut unbounded = input;
    unbounded.body = serde_json::json!({"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_tokens":33}).to_string();
    assert!(scope.request_facts("alice", &unbounded).is_err());
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn retry_key_stays_fixed_while_exact_wire_or_scope_changes_invalidate_command(
        prompt in "[a-z]{1,64}", extra in "[a-z]{1,64}", limit in 1u64..65,
    ) {
        let scope = scope();
        let a = submission("retry", &prompt);
        let mut b = a.clone();
        b.body.push(' ');
        prop_assert_eq!(scope.turn_family(&a).expect("Session contract fixture"), scope.turn_family(&b).expect("Session contract fixture"));
        prop_assert!(scope.submission_digest("alice", &a).expect("Session contract fixture") != scope.submission_digest("alice", &b).expect("Session contract fixture"));
        let mut changed = scope.clone();
        changed.max_turns = limit;
        changed.domains.history = format!("history-{extra}");
        prop_assert!(scope.digest().expect("Session contract fixture") != changed.digest().expect("Session contract fixture"));
        prop_assert!(scope.turn_family(&a).expect("Session contract fixture") != changed.turn_family(&a).expect("Session contract fixture"));
    }
}
