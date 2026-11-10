// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::fixture_nodes;
use std::collections::BTreeSet;
use weaver_contracts::{ProviderPlan, body_digest};
use weaver_ledger::Ledger;

#[test]
fn hard_fact_prefix_change_fences_stale_work_and_unsent_provider_output() {
    use weaver_contracts::{FactFeed, FactIntent, SourceAuthority, SourceIdentity};
    use weaver_ledger::FactPreparation;

    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("facts.db");
    let caller = SourceIdentity {
        certificate_sha256: body_digest("certificate"),
        public_key_sha256: body_digest("key"),
        credential_sha256: body_digest("credential"),
    };
    let feed = FactFeed {
        domain: "availability".into(),
        authority: SourceAuthority {
            epoch: 0,
            identity: caller.clone(),
        },
        family: "f".into(),
        root: "infer".into(),
        dependencies: vec![("second".into(), "infer".into())],
        workflow: None,
        workflow_path: vec![],
        workflow_dag: false,
        workflow_choice: false,
        workflow_selectors: vec![],
    };
    let mut initial = Ledger::open(&path).expect("ledger");
    initial.configure_fact_feed(Some(&feed)).expect("feed");
    initial
        .with_authenticated_source(&caller, |_| Ok(()))
        .expect("source enrollment");
    initial.close().expect("close");
    let (mut ledger, plan) = fixture_nodes(&path, &["infer", "second"]);
    let stage = |ledger: &mut Ledger, intent: &FactIntent| {
        ledger
            .with_authenticated_source(&caller, |ledger| ledger.stage_fact_intent(intent))
            .expect("staged")
    };
    let prepare = |ledger: &mut Ledger, barrier: &_| {
        let FactPreparation::Pending(work) = ledger
            .with_authenticated_source(&caller, |ledger| ledger.prepare_fact_projection(barrier))
            .expect("prepared")
        else {
            panic!("expected pending intent");
        };
        work
    };
    let affected = vec!["infer".into(), "second".into()];
    let resolve = |ledger: &mut Ledger, work: &_| {
        ledger.with_authenticated_source(&caller, |ledger| {
            ledger.resolve_fact_projection(work, affected.clone())
        })
    };
    let mut intent = FactIntent {
        operation_id: "a".into(),
        domain: feed.domain.clone(),
        source_epoch: 0,
        revision: 1,
        previous_snapshot: "0".repeat(64),
        expected_floor: 0,
        available: true,
    };
    let a = stage(&mut ledger, &intent);
    let work = prepare(&mut ledger, &a);
    resolve(&mut ledger, &work).expect("A installed");
    ledger.enqueue_provider(&plan).expect("original hold");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("dispatch");
    let unsent = ledger
        .prepare_provider_release(&permit, "tail", "protobuf", 1)
        .expect("prepared output");
    intent = FactIntent {
        operation_id: "b".into(),
        revision: 2,
        previous_snapshot: a.snapshot,
        expected_floor: a.floor,
        available: false,
        ..intent
    };
    let b = stage(&mut ledger, &intent);
    let stale = prepare(&mut ledger, &b);
    let mut released = false;
    assert!(
        ledger
            .release_provider(&permit, unsent, "protobuf", |_| {
                released = true;
                Ok(())
            })
            .is_err()
    );
    assert!(!released);
    assert_eq!(ledger.held("f").expect("hold retained"), 4);
    intent = FactIntent {
        operation_id: "a-again".into(),
        revision: 3,
        previous_snapshot: b.snapshot.clone(),
        expected_floor: b.floor,
        available: true,
        ..intent
    };
    let restored = stage(&mut ledger, &intent);
    assert!(resolve(&mut ledger, &stale).is_err());
    let fresh = prepare(&mut ledger, &b);
    assert_ne!(stale.pending_prefix, fresh.pending_prefix);
    assert!(
        ledger
            .with_authenticated_source(&caller, |ledger| {
                ledger.resolve_fact_projection(&fresh, vec!["infer".into()])
            })
            .is_err()
    );
    let withdrawn = resolve(&mut ledger, &fresh).expect("B installed");
    assert!(withdrawn.remaining_pending_prefix.is_some());
    let mut dependent = plan.clone();
    dependent.node = "second".into();
    assert!(ledger.enqueue_provider(&dependent).is_err());
    let work = prepare(&mut ledger, &restored);
    assert_eq!(
        work.pending_prefix,
        withdrawn
            .remaining_pending_prefix
            .expect("remaining prefix")
    );
    resolve(&mut ledger, &work).expect("new A installed");
    assert!(matches!(
        ledger.prepare_provider_release(&permit, "tail", "protobuf", 1),
        Err(weaver_contracts::Error::Conflict(
            "provider permit has a stale hard fact cut"
        ))
    ));
    ledger
        .enqueue_provider(&dependent)
        .expect("restored dependent");
    ledger
        .rotate_source_authority(
            &caller,
            &weaver_contracts::SourceRotation {
                operation_id: "retire-feed-key".into(),
                expected_epoch: 0,
                next: SourceIdentity {
                    certificate_sha256: body_digest("new certificate"),
                    public_key_sha256: body_digest("new key"),
                    credential_sha256: body_digest("new credential"),
                },
            },
        )
        .expect("retire source authority");
    assert!(
        ledger
            .consume_provider("f", "second", &BTreeSet::from(["primary".into()]))
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("retired feed cannot refund"), 8);
}

#[test]
fn provider_workflow_rechecks_prepared_floor_and_frontier_before_one_reservation() {
    check_workflow_rechecks_prepared_floor(false);
}

#[test]
fn nested_workflow_rejects_stale_decision_and_keeps_winner_after_reopen() {
    check_workflow_rechecks_prepared_floor(true);
}

fn check_workflow_rechecks_prepared_floor(nested: bool) {
    use weaver_contracts::{
        FactFeed, FactIntent, ProviderWorkflow, SourceAuthority, SourceIdentity,
    };
    use weaver_ledger::FactPreparation;

    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("workflow.db");
    let caller = SourceIdentity {
        certificate_sha256: body_digest("certificate"),
        public_key_sha256: body_digest("key"),
        credential_sha256: body_digest("credential"),
    };
    let mut ledger = Ledger::open(&path).expect("ledger");
    ledger
        .with_authenticated_source(&caller, |_| Ok(()))
        .expect("source");
    ledger.close().expect("close");
    let nodes: &[&str] = if nested {
        &["infer", "second", "left", "right", "skip", "join"]
    } else {
        &["infer", "second"]
    };
    let (mut ledger, predecessor) = fixture_nodes(&path, nodes);
    let mut successor = predecessor.clone();
    successor.node = "second".into();
    let mut feed = FactFeed {
        domain: "availability".into(),
        authority: SourceAuthority {
            epoch: 0,
            identity: caller.clone(),
        },
        family: predecessor.family.clone(),
        root: predecessor.node.clone(),
        dependencies: vec![(successor.node.clone(), predecessor.node.clone())],
        workflow: Some(ProviderWorkflow {
            predecessor: predecessor.node.clone(),
            successor: successor.node.clone(),
        }),
        workflow_path: vec![],
        workflow_dag: false,
        workflow_choice: false,
        workflow_selectors: vec![],
    };
    if nested {
        feed.workflow = None;
        feed.workflow_dag = true;
        feed.workflow_path = nodes.iter().map(|node| (*node).into()).collect();
        feed.dependencies = [
            ("join", "left"),
            ("join", "right"),
            ("join", "skip"),
            ("left", "second"),
            ("right", "second"),
            ("second", "infer"),
            ("skip", "infer"),
        ]
        .into_iter()
        .map(|(child, parent)| (child.into(), parent.into()))
        .collect();
        feed.workflow_selectors = [["infer", "second", "skip"], ["second", "left", "right"]]
            .map(|row| row.map(String::from))
            .to_vec();
    }
    ledger
        .configure_fact_feed(Some(&feed))
        .expect("installed workflow");
    let mut affected: Vec<String> = nodes.iter().map(|node| (*node).into()).collect();
    affected.sort();
    let project = |ledger: &mut Ledger, intent: &FactIntent| {
        ledger
            .with_authenticated_source(&caller, |ledger| {
                let barrier = ledger.stage_fact_intent(intent)?;
                let FactPreparation::Pending(work) = ledger.prepare_fact_projection(&barrier)?
                else {
                    panic!("expected pending intent");
                };
                ledger.resolve_fact_projection(&work, affected.clone())?;
                Ok(barrier)
            })
            .expect("projected fact")
    };
    let intent = FactIntent {
        operation_id: "first-fact".into(),
        domain: feed.domain.clone(),
        source_epoch: 0,
        revision: 1,
        previous_snapshot: "0".repeat(64),
        expected_floor: 0,
        available: true,
    };
    let a = project(&mut ledger, &intent);
    assert!(
        ledger
            .prepare_provider_progression(&predecessor, &successor)
            .is_err()
    );
    assert!(ledger.enqueue_provider(&successor).is_err());
    ledger
        .enqueue_provider(&predecessor)
        .expect("predecessor queued");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("dispatch");
    let release = ledger
        .prepare_provider_release(&permit, "response", "protobuf", 1)
        .expect("prepared");
    ledger
        .release_provider(&permit, release, "protobuf", |_| Ok(()))
        .expect("released");
    assert!(
        ledger
            .prepare_provider_progression(&predecessor, &successor)
            .is_err(),
        "released prefix is not terminal completion"
    );
    ledger
        .complete_provider_with_result(
            &permit,
            "protobuf",
            None,
            nested.then_some(r#"{"route":"left"}"#),
        )
        .expect("complete response");

    let stale = ledger
        .prepare_provider_progression(&predecessor, &successor)
        .expect("first frontier");
    let b = project(
        &mut ledger,
        &FactIntent {
            operation_id: "second-fact".into(),
            revision: 2,
            previous_snapshot: a.snapshot,
            expected_floor: a.floor,
            ..intent.clone()
        },
    );
    assert!(
        ledger
            .enqueue_provider_progression(&successor, "", None, Some(&stale))
            .is_err()
    );
    assert_eq!(
        ledger.held("f").expect("stale proposal reserved nothing"),
        4
    );
    let plans: Vec<_> = nodes
        .iter()
        .map(|node| ProviderPlan {
            node: (*node).into(),
            ..predecessor.clone()
        })
        .collect();
    let cut = ledger.observe_workflow(&plans).expect("frontier");
    assert_eq!(cut.available, nodes);
    assert_eq!(cut.complete, ["infer"]);
    assert_eq!(cut.pending, nodes[1..]);
    if nested {
        let graph = cut.nested.expect("nested graph");
        assert!(graph.decisions.is_empty());
        assert!(!graph.predecessors.contains_key("join"));
    }
    let current = ledger
        .prepare_provider_progression(&predecessor, &successor)
        .expect("refreshed frontier");
    ledger
        .enqueue_provider_progression(&successor, "", None, Some(&current))
        .expect("one successor claim");
    assert!(
        ledger
            .enqueue_provider_progression(&successor, "", None, Some(&current))
            .is_err()
    );
    let replay = ledger
        .prepare_provider_progression(&predecessor, &successor)
        .expect("winning frontier");
    ledger
        .enqueue_provider_progression(&successor, "", None, Some(&replay))
        .expect("exact replay");
    assert_eq!(ledger.held("f").expect("one successor hold"), 8);
    if !nested {
        let permit = ledger
            .consume_provider("f", "second", &BTreeSet::from(["primary".into()]))
            .expect("consume successor");
        ledger
            .dispatch_provider(&permit, || Ok(()))
            .expect("dispatch successor");
        let release = ledger
            .prepare_provider_release(&permit, "response", "protobuf", 1)
            .expect("prepare successor response");
        ledger
            .release_provider(&permit, release, "protobuf", |_| Ok(()))
            .expect("release successor response");
        ledger
            .complete_provider_with_result(&permit, "protobuf", None, None)
            .expect("complete successor");
        assert_eq!(
            ledger.observe_workflow(&plans).expect("frontier").complete,
            ["infer", "second"]
        );
        let mut storage =
            weaver_ledger::persistence::Session::open(&path).expect("fault injection");
        weaver_ledger::persistence::exec(
            &storage,
            "INSERT INTO metering_deployment(singleton,record) VALUES(1,'{}')",
            (),
        )
        .expect("change metering deployment after a completed observation");
        assert!(
            ledger.observe_workflow(&plans).is_err(),
            "a new frontier transaction must read the current deployment"
        );
        weaver_ledger::persistence::exec(&storage, "DELETE FROM metering_deployment", ())
            .expect("restore deployment");
        assert_eq!(
            ledger
                .observe_workflow(&plans)
                .expect("restored frontier")
                .complete,
            ["infer", "second"]
        );
        let fault = weaver_ledger::persistence::begin(&mut storage).expect("open WAL writer");
        weaver_ledger::persistence::exec(
            &fault,
            "DELETE FROM provider_workflow_transitions WHERE successor=?1",
            ["second"],
        )
        .expect("remove successor transition");
        assert_eq!(
            ledger
                .observe_workflow(&plans)
                .expect("committed frontier")
                .complete,
            ["infer", "second"]
        );
        fault.commit().expect("commit missing transition");
        assert!(matches!(
            ledger.observe_workflow(&plans),
            Err(weaver_contracts::Error::Conflict(
                "provider successor has no committed transition"
            ))
        ));
    } else {
        ledger.close().expect("close");
        let mut ledger = Ledger::open(&path).expect("reopen");
        let cut = ledger
            .observe_workflow(&plans)
            .expect("frontier")
            .nested
            .expect("nested graph");
        assert_eq!(cut.decisions, [("infer".into(), "left".into())]);
        assert!(
            ledger
                .provider_receipt("f", "skip")
                .expect("skipped arm")
                .is_none()
        );
        assert!(!cut.predecessors.contains_key("join"));
        assert_eq!(ledger.held("f").expect("preserved winner hold"), 8);
        ledger
            .with_authenticated_source(&caller, |ledger| {
                let barrier = ledger.stage_fact_intent(&FactIntent {
                    operation_id: "withdraw-after-reopen".into(),
                    revision: 3,
                    previous_snapshot: b.snapshot,
                    expected_floor: b.floor,
                    available: false,
                    ..intent
                })?;
                let pending = ledger.observe_workflow(&plans)?;
                assert!(pending.available.is_empty());
                assert_eq!(pending.complete, ["infer"]);
                let FactPreparation::Pending(work) = ledger.prepare_fact_projection(&barrier)?
                else {
                    panic!("expected pending withdrawal");
                };
                ledger.resolve_fact_projection(&work, affected.clone())?;
                let withdrawn = ledger.observe_workflow(&plans)?;
                assert!(withdrawn.available.is_empty());
                assert_eq!(withdrawn.complete, ["infer"]);
                assert_eq!(withdrawn.pending, nodes[1..]);
                Ok(())
            })
            .expect("withdrawal fences batched frontier after reopen");
        let storage = weaver_ledger::persistence::Session::open(&path).expect("fault injection");
        weaver_ledger::persistence::exec(&storage, "DELETE FROM domain_history", ())
            .expect("remove shared history");
        assert!(matches!(
            ledger.observe_workflow(&plans),
            Err(weaver_contracts::Error::Conflict(
                "original domain history missing or inconsistent"
            ))
        ));
    }
}
