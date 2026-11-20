// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    Ledger, ProviderSessionRequest,
    persistence::{Session, exec, one},
};
use std::{
    collections::BTreeSet,
    sync::{Arc, Barrier},
};
use weaver_contracts::{
    CHAT_TURN_SSE, DomainBinding, FactBarrier, FactFeed, FactIntent, ProviderPlan, ProviderProfile,
    ProviderRoute, ProviderSessionScope, ProviderTurnDerivation, ProviderTurnSubmission,
    Publication, PublicationKey, SourceAuthority, SourceIdentity, SourceRotation, Task,
    body_digest,
};

fn source() -> SourceIdentity {
    SourceIdentity {
        certificate_sha256: body_digest("session-cert"),
        public_key_sha256: body_digest("session-key"),
        credential_sha256: body_digest("session-credential"),
    }
}
fn fixture(path: &std::path::Path, max_turns: u64) -> (Ledger, ProviderSessionScope) {
    let mut ledger = Ledger::open(path).expect("native Session fixture");
    let feed = FactFeed {
        domain: "session-facts".into(),
        authority: SourceAuthority {
            epoch: 0,
            identity: source(),
        },
        family: "session-a".into(),
        root: "infer".into(),
        dependencies: vec![],
        workflow: None,
        workflow_path: vec![],
        workflow_dag: false,
        workflow_choice: false,
        workflow_selectors: vec![],
    };
    ledger
        .configure_fact_feed(Some(&feed))
        .expect("native Session fixture");
    let publication = Publication {
        operation_id: "session-publication".into(),
        expected_revision: None,
        fence: 1,
        policy: include_str!("../../../../prod/policies/provider/provider.cedar")
            .replace("context.family == \"f\"", "context.family like \"turn:*\"")
            .replace("openai.chat-text-sse.v1", CHAT_TURN_SSE),
        schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
    };
    ledger
        .with_authenticated_source(&source(), |l| l.publish_authority(&publication))
        .expect("native Session fixture");
    let profile = ProviderProfile {
        id: "p".into(),
        protocol: CHAT_TURN_SSE.into(),
        max_output_tokens: 32,
        max_messages: 8,
        max_body_bytes: 4096,
    };
    let scope = ProviderSessionScope {
        template: Task {
            family: "session-a".into(),
            principal: "alice".into(),
            profile: "p".into(),
            provider_profile: Some(profile),
            nodes: vec!["infer".into()],
            targets: vec!["primary".into()],
            endpoints: [(
                "primary".into(),
                "https://provider.invalid/v1/chat/completions".into(),
            )]
            .into(),
            body_digests: Default::default(),
            stream_contracts: Default::default(),
            node_cost_bounds: [("infer".into(), 4)].into(),
            models: vec!["model-a".into()],
            budget: 8,
        },
        domains: DomainBinding {
            origin: "session-a".into(),
            budget: "shared-budget".into(),
            history: "shared-history".into(),
            budget_limit: 8,
        },
        publication: PublicationKey {
            operation_id: publication.operation_id.clone(),
            digest: publication.digest().expect("native Session fixture"),
        },
        max_turns,
    };
    assert!(
        ledger.register_provider_session(&scope).is_err(),
        "operation owner cannot declare source scopes"
    );
    ledger
        .with_authenticated_source(&source(), |l| l.register_provider_session(&scope))
        .expect("native Session fixture");
    advance(&mut ledger, true);
    (ledger, scope)
}
fn stage(ledger: &mut Ledger, available: bool) -> FactBarrier {
    ledger
        .with_authenticated_source(&source(), |l| {
            let state = l.inspect_fact_feed()?;
            l.stage_fact_intent(&FactIntent {
                operation_id: format!("fact-{}", state.revision + 1),
                domain: state.domain,
                source_epoch: state.source_epoch,
                revision: state.revision + 1,
                previous_snapshot: state.snapshot,
                expected_floor: state.floor,
                available,
            })
        })
        .expect("native Session fixture")
}
fn resolve(ledger: &mut Ledger, barrier: &FactBarrier) {
    ledger
        .with_authenticated_source(&source(), |l| {
            let crate::FactPreparation::Pending(work) = l.prepare_fact_projection(barrier)? else {
                panic!("pending");
            };
            l.resolve_fact_projection(&work, vec!["infer".into()])
        })
        .expect("native Session fixture");
}
fn advance(ledger: &mut Ledger, available: bool) {
    let barrier = stage(ledger, available);
    resolve(ledger, &barrier);
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config {cases:64,rng_seed:proptest::test_runner::RngSeed::Fixed(293),..Default::default()})]
    #[test]
    fn discovery_matches_current_facts_without_execution_effects(
        availability in proptest::collection::vec(proptest::bool::ANY, 1..7)
    ) {
        let temp=tempfile::tempdir().expect("native Session fixture");
        let path=temp.path().join("discovery-property.db");
        let (mut ledger,scope)=fixture(&path,3);
        let mut previous=ledger.provider_session_catalog("session-a","alice").expect("native Session fixture").version;
        for available in availability {
            let barrier=stage(&mut ledger,available);
            proptest::prop_assert!(ledger.provider_session_catalog("session-a","alice").is_err());
            resolve(&mut ledger,&barrier);
            proptest::prop_assert!(ledger.provider_session_catalog("session-a","foreign-principal").is_err());
            let observed=ledger.provider_session_catalog("session-a","alice");
            proptest::prop_assert_eq!(observed.is_ok(),available);
            if let Ok(catalog)=observed {
                proptest::prop_assert_eq!(&catalog.models,&scope.template.models);
                proptest::prop_assert_eq!(&catalog.scope_commitment,&scope.digest().expect("native Session fixture"));
                proptest::prop_assert_ne!(&catalog.version,&previous);
                previous=catalog.version;
            }
        }
        ledger.require_quiescent().expect("native Session fixture");
        let storage=Session::open(&path).expect("native Session fixture");
        for table in ["tasks","original_tasks","provider_session_turns","provider_runs"] {
            let count:i64=one(&storage,&format!("SELECT COUNT(*) FROM {table}"),(),|r|r.get(0)).expect("native Session fixture");
            proptest::prop_assert_eq!(count,0,"discovery mutated {}",table);
        }
    }
}

#[test]
fn discovery_is_principal_scoped_and_has_no_execution_side_effects() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("catalog.db");
    let (mut ledger, scope) = fixture(&path, 3);
    let catalog = ledger
        .provider_session_catalog("session-a", "alice")
        .expect("native Session fixture");
    assert_eq!(
        catalog.scope_commitment,
        scope.digest().expect("native Session fixture")
    );
    assert_eq!(catalog.models, scope.template.models);
    assert_eq!(
        Some(catalog.profile.clone()),
        scope.template.provider_profile
    );
    assert_eq!(
        catalog,
        ledger
            .provider_session_catalog("session-a", "alice")
            .expect("native Session fixture")
    );
    assert!(
        ledger
            .provider_session_catalog("session-a", "mallory")
            .is_err()
    );
    assert!(ledger.provider_session_catalog("missing", "alice").is_err());
    ledger.require_quiescent().expect("native Session fixture");
    let storage = Session::open(&path).expect("native Session fixture");
    for table in [
        "tasks",
        "original_tasks",
        "provider_session_turns",
        "provider_runs",
    ] {
        let count: i64 = one(
            &storage,
            &format!("SELECT COUNT(*) FROM {table}"),
            (),
            |r| r.get(0),
        )
        .expect("native Session fixture");
        assert_eq!(count, 0, "discovery mutated {table}");
    }
}

#[test]
fn discovery_rechecks_pending_withdrawal_restart_and_a_b_a() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("catalog-facts.db");
    let (mut ledger, _) = fixture(&path, 3);
    let first = ledger
        .provider_session_catalog("session-a", "alice")
        .expect("native Session fixture");
    let barrier = stage(&mut ledger, false);
    assert!(
        ledger
            .provider_session_catalog("session-a", "alice")
            .is_err()
    );
    resolve(&mut ledger, &barrier);
    assert!(
        ledger
            .provider_session_catalog("session-a", "alice")
            .is_err()
    );
    advance(&mut ledger, true);
    let restored = ledger
        .provider_session_catalog("session-a", "alice")
        .expect("native Session fixture");
    assert_eq!(first.scope_commitment, restored.scope_commitment);
    assert_eq!(first.models, restored.models);
    assert_ne!(
        first.version, restored.version,
        "ABA must change the observed fact prefix"
    );
    ledger.close().expect("native Session fixture");
    let mut ledger = Ledger::open(&path).expect("native Session fixture");
    assert_eq!(
        restored,
        ledger
            .provider_session_catalog("session-a", "alice")
            .expect("native Session fixture")
    );
    ledger
        .with_authenticated_source(&source(), |l| {
            l.rotate_source_authority(
                &source(),
                &SourceRotation {
                    operation_id: "catalog-rotation".into(),
                    expected_epoch: 0,
                    next: SourceIdentity {
                        certificate_sha256: body_digest("next-cert"),
                        public_key_sha256: body_digest("next-key"),
                        credential_sha256: body_digest("next-token"),
                    },
                },
            )
        })
        .expect("native Session fixture");
    assert!(
        ledger
            .provider_session_catalog("session-a", "alice")
            .is_err()
    );
}
fn request(key: &str, prompt: &str) -> ProviderSessionRequest {
    ProviderSessionRequest {
        session: "session-a".into(),
        principal: "alice".into(),
        submission: ProviderTurnSubmission {
            operation_id: key.into(),
            body: serde_json::json!({"model":"model-a","stream":true,
            "messages":[{"role":"user","content":prompt}],"max_tokens":32})
            .to_string(),
        },
    }
}
// Explicit derivation fixture, not evidence that the Scheme owner is connected.
fn derive(cut: &crate::ProviderSessionCut) -> ProviderTurnDerivation {
    let mut task = cut.scope().template.clone();
    task.family = cut
        .scope()
        .turn_family(&cut.request().submission)
        .expect("native Session fixture");
    let plan = ProviderPlan {
        family: task.family.clone(),
        node: "infer".into(),
        profile: task.profile.clone(),
        profile_commitment: task
            .provider_profile
            .as_ref()
            .expect("native Session fixture")
            .digest()
            .expect("native Session fixture"),
        model: "model-a".into(),
        body: cut.request().submission.body.clone(),
        routes: vec![ProviderRoute {
            target: "primary".into(),
            endpoint: task.endpoints["primary"].clone(),
        }],
        ceiling: 4,
        revision: cut.revision(),
        fence: cut.fence(),
    };
    task.body_digests
        .insert("infer".into(), body_digest(&plan.body));
    task.stream_contracts.insert(
        "infer".into(),
        plan.digest().expect("native Session fixture"),
    );
    let mut domains = cut.scope().domains.clone();
    domains.origin.clone_from(&task.family);
    ProviderTurnDerivation {
        task,
        plan,
        domains,
    }
}
fn admit(ledger: &mut Ledger, key: &str) -> ProviderTurnDerivation {
    let cut = ledger
        .prepare_provider_turn(request(key, key))
        .expect("native Session fixture");
    ledger
        .register_provider_turn(&cut, &derive(&cut))
        .expect("native Session fixture")
}

#[test]
fn changing_turns_share_exposure_and_restart_preserves_retry_decisions() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("session.db");
    let (mut ledger, _) = fixture(&path, 3);
    let first = admit(&mut ledger, "first");
    let second = admit(&mut ledger, "second");
    assert_ne!(first.task.family, second.task.family);
    assert_eq!(
        ledger
            .execution_domains(&first.task.family)
            .expect("native Session fixture")
            .held,
        0
    );
    ledger
        .enqueue_provider(&first.plan)
        .expect("native Session fixture");
    ledger
        .enqueue_provider(&second.plan)
        .expect("native Session fixture");
    assert_eq!(
        ledger
            .execution_domains(&first.task.family)
            .expect("native Session fixture")
            .held,
        8
    );
    let third = admit(&mut ledger, "third");
    assert!(ledger.enqueue_provider(&third.plan).is_err());
    assert!(
        ledger
            .prepare_provider_turn(request("fourth", "fourth"))
            .is_ok()
    );
    let fourth = ledger
        .prepare_provider_turn(request("fourth", "fourth"))
        .expect("native Session fixture");
    assert!(
        ledger
            .register_provider_turn(&fourth, &derive(&fourth))
            .is_err()
    );
    ledger.close().expect("native Session fixture");
    let mut ledger = Ledger::open(&path).expect("native Session fixture");
    assert_eq!(admit(&mut ledger, "first"), first);
    assert!(
        ledger
            .prepare_provider_turn(request("first", "changed bytes"))
            .is_err()
    );
    assert_eq!(
        ledger
            .execution_domains(&first.task.family)
            .expect("native Session fixture")
            .held,
        8
    );
    let storage = Session::open(&path).expect("native Session fixture");
    let count: i64 = one(
        &storage,
        "SELECT COUNT(*) FROM provider_session_turns",
        (),
        |r| r.get(0),
    )
    .expect("native Session fixture");
    assert_eq!(count, 3);
}

#[test]
fn four_concurrent_admissions_cannot_exceed_the_session_turn_limit() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("race.db");
    let (mut ledger, _) = fixture(&path, 1);
    let work: Vec<_> = (0..4)
        .map(|i| {
            let cut = ledger
                .prepare_provider_turn(request(&format!("turn-{i}"), "hello"))
                .expect("native Session fixture");
            let d = derive(&cut);
            (cut, d)
        })
        .collect();
    let barrier = Arc::new(Barrier::new(4));
    let successes = std::thread::scope(|scope| {
        let jobs: Vec<_> = work
            .into_iter()
            .map(|(cut, d)| {
                let path = &path;
                let barrier = barrier.clone();
                scope.spawn(move || {
                    let mut l = Ledger::open(path).expect("native Session fixture");
                    barrier.wait();
                    l.register_provider_turn(&cut, &d).is_ok()
                })
            })
            .collect();
        jobs.into_iter()
            .map(|job| job.join().expect("native Session fixture"))
            .filter(|ok| *ok)
            .count()
    });
    assert_eq!(successes, 1);
    let storage = Session::open(&path).expect("native Session fixture");
    for table in [
        "tasks",
        "original_tasks",
        "provider_session_turns",
        "execution_origins",
    ] {
        let count: i64 = one(
            &storage,
            &format!("SELECT COUNT(*) FROM {table}"),
            (),
            |r| r.get(0),
        )
        .expect("native Session fixture");
        assert_eq!(count, 1, "{table}");
    }
}

#[test]
fn parent_intents_and_a_b_a_reject_stale_derivation_and_unsent_output() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("withdraw.db");
    let (mut ledger, _) = fixture(&path, 3);
    let stale = ledger
        .prepare_provider_turn(request("stale", "stale"))
        .expect("native Session fixture");
    let first = admit(&mut ledger, "first");
    ledger
        .enqueue_provider(&first.plan)
        .expect("native Session fixture");
    let permit = ledger
        .consume_provider(
            &first.plan.family,
            "infer",
            &BTreeSet::from(["primary".into()]),
        )
        .expect("native Session fixture");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("native Session fixture");
    let output = ledger
        .prepare_provider_release(&permit, "tail", "protobuf", 1)
        .expect("native Session fixture");
    let barrier = stage(&mut ledger, false);
    assert!(
        ledger
            .register_provider_turn(&stale, &derive(&stale))
            .is_err()
    );
    let mut calls = 0;
    assert!(
        ledger
            .release_provider(&permit, output, "protobuf", |_| {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    resolve(&mut ledger, &barrier);
    assert!(
        ledger
            .prepare_provider_turn(request("blocked", "blocked"))
            .is_err()
    );
    advance(&mut ledger, true);
    assert!(
        ledger
            .register_provider_turn(&stale, &derive(&stale))
            .is_err()
    );
    let second = admit(&mut ledger, "second");
    ledger
        .enqueue_provider(&second.plan)
        .expect("native Session fixture");
    assert_eq!(
        ledger
            .execution_domains(&second.task.family)
            .expect("native Session fixture")
            .held,
        8
    );
    assert!(
        ledger
            .dispatch_provider(&permit, || {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(calls, 0);
}

#[test]
fn missing_parent_link_cannot_bypass_fact_guard_or_be_backfilled_on_retry() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("missing.db");
    let (mut ledger, _) = fixture(&path, 2);
    let first = admit(&mut ledger, "first");
    ledger
        .enqueue_provider(&first.plan)
        .expect("native Session fixture");
    let storage = Session::open(&path).expect("native Session fixture");
    exec(
        &storage,
        "DELETE FROM provider_session_turns WHERE family=?1",
        [first.task.family.as_str()],
    )
    .expect("native Session fixture");
    assert!(
        ledger
            .consume_provider(
                &first.plan.family,
                "infer",
                &BTreeSet::from(["primary".into()])
            )
            .is_err()
    );
    let retry = ledger
        .prepare_provider_turn(request("first", "first"))
        .expect("native Session fixture");
    assert!(
        ledger
            .register_provider_turn(&retry, &derive(&retry))
            .is_err()
    );
    assert_eq!(
        ledger
            .held(&first.task.family)
            .expect("native Session fixture"),
        4
    );
}

#[test]
fn source_rotation_fences_a_prepared_cut_and_an_already_admitted_turn() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("rotation.db");
    let (mut ledger, _) = fixture(&path, 3);
    let cut = ledger
        .prepare_provider_turn(request("stale", "stale"))
        .expect("native Session fixture");
    let first = admit(&mut ledger, "first");
    ledger
        .enqueue_provider(&first.plan)
        .expect("native Session fixture");
    let next = SourceIdentity {
        certificate_sha256: body_digest("next-cert"),
        public_key_sha256: body_digest("next-key"),
        credential_sha256: body_digest("next-credential"),
    };
    ledger
        .with_authenticated_source(&source(), |l| {
            l.rotate_source_authority(
                &source(),
                &SourceRotation {
                    operation_id: "rotate".into(),
                    expected_epoch: 0,
                    next,
                },
            )
        })
        .expect("native Session fixture");
    assert!(ledger.register_provider_turn(&cut, &derive(&cut)).is_err());
    assert!(
        ledger
            .consume_provider(
                &first.plan.family,
                "infer",
                &BTreeSet::from(["primary".into()])
            )
            .is_err()
    );
    assert_eq!(
        ledger
            .held(&first.task.family)
            .expect("native Session fixture"),
        4
    );
}

#[test]
fn four_turns_contend_for_one_shared_budget_without_allocating_four_budgets() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("budget-race.db");
    let (mut ledger, _) = fixture(&path, 4);
    let turns: Vec<_> = (0..4)
        .map(|i| admit(&mut ledger, &format!("turn-{i}")))
        .collect();
    let family = turns[0].task.family.clone();
    let barrier = Arc::new(Barrier::new(4));
    let successes = std::thread::scope(|scope| {
        let jobs: Vec<_> = turns
            .into_iter()
            .map(|turn| {
                let path = &path;
                let barrier = barrier.clone();
                scope.spawn(move || {
                    let mut l = Ledger::open(path).expect("native Session fixture");
                    barrier.wait();
                    l.enqueue_provider(&turn.plan).is_ok()
                })
            })
            .collect();
        jobs.into_iter()
            .map(|job| job.join().expect("native Session fixture"))
            .filter(|ok| *ok)
            .count()
    });
    assert_eq!(successes, 2);
    assert_eq!(
        ledger
            .execution_domains(&family)
            .expect("native Session fixture")
            .held,
        8
    );
    ledger.close().expect("native Session fixture");
    let ledger = Ledger::open(&path).expect("native Session fixture");
    assert_eq!(
        ledger
            .execution_domains(&family)
            .expect("native Session fixture")
            .held,
        8
    );
    let storage = Session::open(&path).expect("native Session fixture");
    let count: i64 = one(&storage, "SELECT COUNT(*) FROM provider_runs", (), |r| {
        r.get(0)
    })
    .expect("native Session fixture");
    assert_eq!(count, 2);
}

#[test]
fn altered_parent_lookup_key_cannot_escape_its_original_commitment() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("redirect.db");
    let (mut ledger, _) = fixture(&path, 2);
    let first = admit(&mut ledger, "first");
    ledger
        .enqueue_provider(&first.plan)
        .expect("native Session fixture");
    let storage = Session::open(&path).expect("native Session fixture");
    exec(
        &storage,
        "UPDATE provider_session_turns SET operation_id='rewritten' WHERE family=?1",
        [first.task.family.as_str()],
    )
    .expect("native Session fixture");
    assert!(matches!(
        ledger.consume_provider(
            &first.plan.family,
            "infer",
            &BTreeSet::from(["primary".into()])
        ),
        Err(weaver_contracts::Error::Denied)
    ));
    assert_eq!(
        ledger
            .held(&first.task.family)
            .expect("native Session fixture"),
        4
    );
}

#[test]
fn rollback_and_lost_acknowledgment_recover_whole_original_decisions_only() {
    use crate::persistence::commit_observer::{Cut, Decision, Observer};
    struct Stop {
        lose_ack: bool,
    }
    impl Observer for Stop {
        fn observe(&self, cut: Cut) -> Decision {
            match (self.lose_ack, cut) {
                (false, Cut::BeforeCommit) => Decision::Rollback,
                (true, Cut::AfterCommit) => Decision::LoseAcknowledgment,
                _ => Decision::Continue,
            }
        }
    }
    for lose_ack in [false, true] {
        let temp = tempfile::tempdir().expect("native Session fixture");
        let path = temp.path().join("commit.db");
        let (mut ledger, _) = fixture(&path, 2);
        let cut = ledger
            .prepare_provider_turn(request("first", "first"))
            .expect("native Session fixture");
        let derived = derive(&cut);
        ledger.observe_provider_commit(Arc::new(Stop { lose_ack }));
        assert!(ledger.register_provider_turn(&cut, &derived).is_err());
        assert!(
            ledger.close().is_err(),
            "unknown transaction cannot return healthy custody"
        );
        let storage = Session::open(&path).expect("native Session fixture");
        for table in [
            "provider_session_turns",
            "original_tasks",
            "tasks",
            "execution_origins",
            "budget_domains",
            "history_domains",
        ] {
            let count: i64 = one(
                &storage,
                &format!("SELECT COUNT(*) FROM {table}"),
                (),
                |r| r.get(0),
            )
            .expect("native Session fixture");
            assert_eq!(count, i64::from(lose_ack), "{table}, lose_ack={lose_ack}");
        }
        let mut ledger = Ledger::open(&path).expect("native Session fixture");
        let recovered = admit(&mut ledger, "first");
        assert_eq!(recovered, derived);
        let count: i64 = one(
            &storage,
            "SELECT COUNT(*) FROM provider_session_turns",
            (),
            |r| r.get(0),
        )
        .expect("native Session fixture");
        assert_eq!(count, 1);
    }
}

#[test]
fn lost_fact_projection_cannot_turn_a_session_into_an_unscoped_request() {
    for orphan_intent in [false, true] {
        let temp = tempfile::tempdir().expect("native Session fixture");
        let path = temp.path().join("fact-loss.db");
        let (mut ledger, _) = fixture(&path, 2);
        let first = admit(&mut ledger, "first");
        let storage = Session::open(&path).expect("native Session fixture");
        if orphan_intent {
            stage(&mut ledger, false);
            exec(&storage, "UPDATE hard_fact_feed SET pending=NULL", ())
                .expect("native Session fixture");
        } else {
            exec(&storage, "DELETE FROM hard_fact_feed", ()).expect("native Session fixture");
        }
        assert!(
            ledger
                .prepare_provider_turn(request("next", "next"))
                .is_err()
        );
        assert!(ledger.enqueue_provider(&first.plan).is_err());
        assert_eq!(
            ledger
                .held(&first.task.family)
                .expect("native Session fixture"),
            0
        );
    }
}

#[test]
fn retry_restores_exact_plan_without_storing_another_copy_of_prompt_bytes() {
    let temp = tempfile::tempdir().expect("native Session fixture");
    let path = temp.path().join("prompt.db");
    let (mut ledger, _) = fixture(&path, 2);
    let submitted = request(
        "first",
        "private request text not needed in Session metadata",
    );
    let cut = ledger
        .prepare_provider_turn(submitted)
        .expect("native Session fixture");
    assert!(cut.retained_derivation().is_none());
    let original = ledger
        .register_provider_turn(&cut, &derive(&cut))
        .expect("native Session fixture");
    ledger.close().expect("native Session fixture");
    let storage = Session::open(&path).expect("native Session fixture");
    let (record, retained): (String, String) = one(
        &storage,
        "SELECT record,derivation FROM provider_session_turns",
        (),
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .expect("native Session fixture");
    assert!(!record.contains("private request text"));
    assert!(!retained.contains("private request text"));
    let mut ledger = Ledger::open(&path).expect("native Session fixture");
    let retry = ledger
        .prepare_provider_turn(request(
            "first",
            "private request text not needed in Session metadata",
        ))
        .expect("native Session fixture");
    assert_eq!(retry.retained_derivation(), Some(&original));
    assert_eq!(
        ledger
            .register_provider_turn(&retry, &derive(&retry))
            .expect("native Session fixture"),
        original
    );
    let mut damaged: serde_json::Value =
        serde_json::from_str(&retained).expect("native Session fixture");
    damaged["fence"] = serde_json::json!(999);
    exec(
        &storage,
        "UPDATE provider_session_turns SET derivation=?1",
        [damaged.to_string().as_str()],
    )
    .expect("native Session fixture");
    assert!(
        ledger
            .register_provider_turn(&retry, &derive(&retry))
            .is_err(),
        "recovery must bind the saved generation too"
    );
}
