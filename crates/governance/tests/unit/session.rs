// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{SessionTurnFacts, SessionTurnInput, SessionTurnSelection};
use proptest::{prop_assert_eq, proptest, test_runner::Config};
use weaver_contracts::{DomainBinding, ProviderSessionScope, PublicationKey};

pub(crate) fn input() -> SessionTurnInput {
    let mut source = crate::source_fixture::source();
    let mut template = source.tasks.remove(0);
    template.nodes.truncate(1);
    template.node_cost_bounds.retain(|node, _| node == "infer");
    template.body_digests.clear();
    template.stream_contracts.clear();
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
                digest: source
                    .publication
                    .digest()
                    .expect("Scheme Session input fixture"),
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
#[test]
fn compact_facts_and_advisory_selection_cannot_change_source_bounds() {
    let input = input();
    input.validate().expect("Scheme Session input fixture");
    for index in 0..5 {
        let mut changed = input.clone();
        match index {
            0 => changed.facts.principal = "mallory".into(),
            1 => changed.facts.model = "model-b".into(),
            2 => changed.facts.output_token_limit = u64::MAX,
            3 => changed.facts.message_count = 0,
            _ => changed.facts.body_bytes = 0,
        }
        assert!(changed.validate().is_err());
    }
    let selected = SessionTurnSelection {
        scope_commitment: input.scope.digest().expect("Scheme Session input fixture"),
        route_indices: vec![0],
    };
    selected
        .validate_for(&input)
        .expect("Scheme Session input fixture");
    for routes in [vec![], vec![1], vec![0, 0], vec![0; 9]] {
        let mut changed = selected.clone();
        changed.route_indices = routes;
        assert!(changed.validate_for(&input).is_err());
    }
    let mut other = input;
    other.scope.max_turns += 1;
    assert!(selected.validate_for(&other).is_err());
}
proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn all_fact_bounds_are_checked_without_prompt_transfer(tokens in 0u64..8193,messages in 0u64..130,bytes in 0u64..2097153) {
        let mut input=input();let profile=input.scope.template.provider_profile.as_ref().expect("Scheme Session input fixture");
        let expected=(1..=profile.max_output_tokens).contains(&tokens) && (1..=profile.max_messages).contains(&messages) && (1..=profile.max_body_bytes).contains(&bytes);
        input.facts.output_token_limit=tokens;input.facts.message_count=messages;input.facts.body_bytes=bytes;
        prop_assert_eq!(input.validate().is_ok(),expected);
        let wire=serde_json::to_value(&input).expect("Scheme Session input fixture");prop_assert_eq!(wire.get("body"),None);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn four_turns_use_the_existing_bounded_owner_without_calling_compile() {
    let (client, inbox) =
        crate::source_lane(std::num::NonZeroUsize::new(4).expect("Scheme Session input fixture"));
    let owner = tokio::task::spawn_blocking(move || {
        inbox.run_with_cancellable_governor(
            (),
            |_, _, _| panic!("a turn must not compile source"),
            |_, work| match work {
                crate::Derivation::SessionTurn(input) => {
                    Ok(crate::DerivationOutput::SessionTurn(SessionTurnSelection {
                        scope_commitment: input
                            .scope
                            .digest()
                            .expect("Scheme Session input fixture"),
                        route_indices: vec![0],
                    }))
                }
                _ => Err(crate::SourceError::Contract),
            },
        )
    });
    let jobs: Vec<_> = (0..4)
        .map(|_| {
            let c = client.clone();
            tokio::spawn(async move { c.session_turn(input()).await })
        })
        .collect();
    for job in jobs {
        tokio::time::timeout(std::time::Duration::from_secs(3), job)
            .await
            .expect("Scheme Session input fixture")
            .expect("Scheme Session input fixture")
            .expect("Scheme Session input fixture");
    }
    client.close();
    tokio::time::timeout(std::time::Duration::from_secs(3), owner)
        .await
        .expect("Scheme Session input fixture")
        .expect("Scheme Session input fixture");
}
