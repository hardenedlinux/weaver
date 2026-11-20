// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Exercise the production affine compiler and fixed Session export, not an advisory double.
use proptest::{
    prop_assert, prop_assert_eq,
    test_runner::{Config, RngSeed, TestRunner},
};
use weaver_contracts::{DomainBinding, ProviderSessionScope, PublicationKey};
use weaver_governance::{
    Derivation, DerivationOutput, SchemeCompiler, SessionTurnFacts, SessionTurnInput,
};
#[path = "../unit/fixture.rs"]
mod fixture;

fn input(routes: usize) -> SessionTurnInput {
    let mut source = fixture::source();
    let mut template = source.tasks.remove(0);
    template.nodes.truncate(1);
    template.node_cost_bounds.retain(|node, _| node == "infer");
    template.body_digests.clear();
    template.stream_contracts.clear();
    let endpoint = template.endpoints["primary"].clone();
    template.targets = (0..routes).map(|index| format!("route-{index}")).collect();
    template.endpoints = template
        .targets
        .iter()
        .map(|target| (target.clone(), endpoint.clone()))
        .collect();
    SessionTurnInput {
        scope: ProviderSessionScope {
            domains: DomainBinding {
                origin: template.family.clone(),
                budget: "shared".into(),
                history: "history".into(),
                budget_limit: template.budget,
            },
            publication: PublicationKey {
                operation_id: source.publication.operation_id.clone(),
                digest: source.publication.digest().expect("source publication"),
            },
            template,
            max_turns: 4,
        },
        facts: SessionTurnFacts {
            principal: "alice".into(),
            model: "model-a".into(),
            output_token_limit: 32,
            message_count: 1,
            body_bytes: 128,
        },
    }
}

fn select(compiler: &mut SchemeCompiler, input: &SessionTurnInput) -> Vec<usize> {
    let DerivationOutput::SessionTurn(selected) = compiler
        .evaluate(&Derivation::SessionTurn(Box::new(input.clone())))
        .expect("fixed Session ABI")
    else {
        panic!("wrong derivation kind")
    };
    selected
        .validate_for(input)
        .expect("independent Rust scope validation");
    assert_eq!(
        selected.scope_commitment,
        input.scope.digest().expect("scope digest")
    );
    selected.route_indices
}

#[test]
fn linked_selector_preserves_warm_scope_rebind_and_fact_boundaries() {
    let mut compiler = SchemeCompiler::initialize().expect("linked Scheme owner");
    let a = input(3);
    let b = input(1);
    // Same owner, repeated scope, changed scope, then A again: an old route
    // vector must never survive a rebind or be confused with a fresh scope.
    for value in [&a, &a, &b, &b, &a] {
        assert_eq!(
            select(&mut compiler, value),
            (0..value.scope.template.targets.len()).collect::<Vec<_>>()
        );
    }
    let mut runner = TestRunner::new(Config {
        cases: 64,
        rng_seed: RngSeed::Fixed(293),
        failure_persistence: None,
        ..Config::default()
    });
    runner
        .run(
            &(1usize..=8, 1u64..=32, 1u64..=4, 1u64..=1024),
            |(routes, tokens, messages, bytes)| {
                let mut value = input(routes);
                value.facts.output_token_limit = tokens;
                value.facts.message_count = messages;
                value.facts.body_bytes = bytes;
                let expected = (0..routes).collect::<Vec<_>>();
                prop_assert_eq!(select(&mut compiler, &value), expected.clone());
                let mut invalid = value.clone();
                match (routes - 1) % 5 {
                    0 => invalid.facts.principal = "foreign".into(),
                    1 => invalid.facts.model = "unapproved".into(),
                    2 => invalid.facts.output_token_limit = u64::MAX,
                    3 => invalid.facts.message_count = 0,
                    _ => invalid.facts.body_bytes = 0,
                }
                prop_assert!(
                    compiler
                        .evaluate(&Derivation::SessionTurn(Box::new(invalid)))
                        .is_err()
                );
                // A rejected input cannot poison the retained Scheme selector.
                prop_assert_eq!(select(&mut compiler, &value), expected);
                Ok(())
            },
        )
        .expect("linked selector properties");
}
