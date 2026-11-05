// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::{cell::Cell, collections::BTreeSet};
use weaver_contracts::{ProviderPlan, ProviderRoute, Task, body_digest};
use weaver_ledger::{Ledger, ProviderDispatch, ProviderRelease};
#[path = "commit_floor.rs"]
mod commit_floor;
#[path = "provider_domains.rs"]
mod domains;
#[path = "provider_observation.rs"]
mod observation;
const POLICY: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../prod/policies/provider/provider.cedar"
));
const SCHEMA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../prod/policies/provider/schema.json"
));
fn fixture(path: &std::path::Path) -> (Ledger, ProviderPlan) {
    fixture_nodes(path, &["infer"])
}

fn fixture_nodes(path: &std::path::Path, nodes: &[&str]) -> (Ledger, ProviderPlan) {
    fixture_with_ceiling(path, nodes, 4)
}
fn fixture_with_ceiling(
    path: &std::path::Path,
    nodes: &[&str],
    ceiling: u64,
) -> (Ledger, ProviderPlan) {
    let mut ledger = Ledger::open(path).expect("ledger");
    let policy = POLICY.replace(
        "context.node == \"infer\"",
        "[\"infer\", \"second\"].contains(context.node)",
    );
    ledger
        .publish_typed(None, &policy, SCHEMA, 1)
        .expect("typed policy");
    let profile: weaver_contracts::ProviderProfile =
        weaver_contracts::decode(include_bytes!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../prod/policies/provider/profile.json"
        )))
        .expect("source profile");
    let plan=ProviderPlan{family:"f".into(),node:"infer".into(),profile:"p".into(),profile_commitment:profile.digest().expect("commitment"),model:"model-a".into(),body:r#"{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}],"max_completion_tokens":32}"#.into(),routes:vec![ProviderRoute{target:"primary".into(),endpoint:"https://provider.invalid/v1/chat/completions".into()}],ceiling,revision:0,fence:1};
    ledger
        .register_task(&Task {
            provider_profile: Some(profile),
            family: "f".into(),
            principal: "alice".into(),
            profile: "p".into(),
            nodes: nodes.iter().map(|node| (*node).into()).collect(),
            targets: vec!["primary".into()],
            endpoints: [("primary".into(), plan.routes[0].endpoint.clone())].into(),
            body_digests: nodes
                .iter()
                .map(|node| ((*node).into(), body_digest(&plan.body)))
                .collect(),
            node_cost_bounds: nodes.iter().map(|node| ((*node).into(), 4)).collect(),
            stream_contracts: nodes
                .iter()
                .map(|node| {
                    let mut original = plan.clone();
                    original.node = (*node).into();
                    ((*node).into(), original.digest().expect("digest"))
                })
                .collect(),
            models: vec!["model-a".into()],
            budget: 8,
        })
        .expect("task");
    (ledger, plan)
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn zero_trust_final_use_requires_durable_claim_and_shared_exposure(
        fault in 0u8..4, phase in 0u8..3
    ) {
        let temp = tempfile::tempdir().expect("directory");
        let path = temp.path().join("zero-trust.db");
        let (mut ledger, plan) = fixture_nodes(&path, &["infer", "second"]);
        ledger.enqueue_provider(&plan).expect("original hold");
        let mut second = plan.clone();
        second.node = "second".into();
        ledger.enqueue_provider(&second).expect("shared hold");
        let permit = ledger.consume_provider("f", "infer", &BTreeSet::from(["primary".into()])).expect("consume");
        let mut callbacks = 0;
        let release = if phase == 1 {
            ledger.dispatch_provider(&permit, || Ok(())).expect("dispatch");
            Some(ledger.prepare_provider_release(&permit, "tail", "protobuf", 1).expect("release"))
        } else if phase == 2 {
            ledger.dispatch_provider(&permit, || Ok(())).expect("dispatch");
            None
        } else { None };
        let connection = weaver_ledger::persistence::Session::open(&path).expect("recovery fault connection");
        let mutation = match fault {
            0 => "DELETE FROM execution_claims WHERE family='f' AND node='infer'",
            1 => "UPDATE execution_claims SET kind='request' WHERE family='f' AND node='infer'",
            2 => "UPDATE provider_runs SET reserved=1 WHERE family='f' AND node='infer'",
            _ => "UPDATE tasks SET held=4 WHERE family='f'",
        };
        weaver_ledger::persistence::exec(&connection, mutation, ()).expect("inject inconsistent recovered projection");
        drop(connection);
        let result = match release {
            Some(range) => ledger.release_provider(&permit, range, "protobuf", |_| { callbacks += 1; Ok(()) }),
            None if phase == 2 => ledger.complete_provider(&permit, "protobuf"),
            None => ledger.dispatch_provider(&permit, || { callbacks += 1;  Ok(()) }),
        };
        prop_assert!(result.is_err(), "inconsistent durable evidence reached final use");
        prop_assert_eq!(callbacks, 0);
        prop_assert_eq!(ledger.provider_receipt("f", "infer").expect("receipt").expect("claim").state,
            weaver_contracts::ProviderState::Unknown);
        drop(ledger);
        let mut restarted = Ledger::open(&path).expect("restart");
        prop_assert!(restarted.consume_provider("f", "infer", &BTreeSet::from(["primary".into()])).is_err());
        prop_assert_eq!(restarted.held("f").expect("retained corrupted projection"), if fault == 3 { 4 } else { 8 });
    }
}

#[test]
fn zero_trust_missing_claim_blocks_queued_consumption_after_restart() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("queued-exposure.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("reservation");
    let connection = weaver_ledger::persistence::Session::open(&path).expect("recovery fault");
    weaver_ledger::persistence::exec(&connection, "DELETE FROM execution_claims", ())
        .expect("missing claim");
    drop(connection);
    drop(ledger);
    let mut restarted = Ledger::open(&path).expect("restart");
    assert!(
        restarted
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .is_err()
    );
    assert_eq!(restarted.held("f").expect("hold"), 4);
    assert_eq!(
        restarted
            .provider_receipt("f", "infer")
            .expect("receipt")
            .expect("run")
            .state,
        weaver_contracts::ProviderState::Queued
    );
}
#[test]
fn rejected_competing_caps_leave_no_claim_or_hold_after_restart() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("provider.db");
    let (mut ledger, original) = fixture(&path);
    let mut bad = original.clone();
    let mut body: serde_json::Value = serde_json::from_str(&bad.body).expect("fixture");
    body["max_tokens"] = serde_json::json!(1000000);
    bad.body = serde_json::to_string(&body).expect("request");
    assert!(ledger.enqueue_provider(&bad).is_err());
    assert_eq!(ledger.held("f").expect("hold"), 0);
    assert!(
        ledger
            .provider_receipt("f", "infer")
            .expect("receipt")
            .is_none()
    );
    assert!(
        ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .is_err()
    );
    drop(ledger);
    let mut restarted = Ledger::open(&path).expect("restart");
    assert_eq!(restarted.held("f").expect("hold"), 0);
    assert!(
        restarted
            .provider_receipt("f", "infer")
            .expect("receipt")
            .is_none()
    );
    restarted
        .enqueue_provider(&original)
        .expect("original admission");
    assert_eq!(restarted.held("f").expect("hold"), 4);
}

#[test]
fn stale_registry_read_and_reopened_worker_preserve_unknown_provider_exposure() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("registry-read-recovery.db");
    let (mut ledger, plan) = fixture(&path);
    ledger
        .enqueue_provider(&plan)
        .expect("original reservation");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("original consumption");
    let mut calls = 0;
    ledger
        .dispatch_provider(&permit, || {
            calls += 1;
            Ok(())
        })
        .expect("original dispatch");
    let range = ledger
        .prepare_provider_release(&permit, "uncertain-tail", "arrow", 2)
        .expect("unknown range before review");
    let change = weaver_contracts::Publication {
        operation_id: "registry-read-recovery".into(),
        expected_revision: Some(0),
        fence: 2,
        policy: "forbid(principal,action,resource);".into(),
        schema: SCHEMA.into(),
    };
    let key = ledger
        .stage_reviewed_authority(&change)
        .expect("original pending");
    let review = weaver_contracts::PublicationReview {
        publication: key.clone(),
        parent: ledger.required_review_parent(&key).expect("actual parent"),
        artifact: "trusted upstream approval fixture".into(),
    };
    // Pin an actual WAL reader before registration. Its later NotFound is an
    // old projection, not evidence that the deciding registry has no record.
    let reader = weaver_ledger::persistence::Session::open(&path).expect("old read owner");
    weaver_ledger::persistence::script(&reader, "BEGIN;").expect("read snapshot");
    let registered = |connection: &weaver_ledger::persistence::driver::Connection| -> i64 {
        weaver_ledger::persistence::one(
            connection,
            "SELECT COUNT(*) FROM authority_reviews WHERE operation_id='registry-read-recovery'",
            (),
            |row| row.get(0),
        )
        .expect("registry count")
    };
    assert_eq!(registered(&reader), 0);
    let mut old_worker = Ledger::open(&path).expect("worker before registration");
    ledger
        .register_approved_review(&review)
        .expect("committed registration with discarded reply");
    assert_eq!(
        registered(&reader),
        0,
        "old snapshot must reproduce delayed absence"
    );
    assert_eq!(
        old_worker
            .publication_review(&key)
            .expect("current deciding read"),
        Some(review.clone())
    );
    let mut replacement = review.clone();
    replacement.artifact = "replacement from stale NotFound".into();
    assert!(
        old_worker.register_approved_review(&replacement).is_err(),
        "old worker must consult current immutable binding"
    );
    assert!(
        ledger
            .release_provider(&permit, range, "arrow", |_| {
                calls += 1;
                Ok(())
            })
            .is_err(),
        "original pending blocks release"
    );
    assert_eq!(ledger.held("f").expect("retained hold"), 4);
    assert_eq!(
        old_worker
            .publish_authority(&change)
            .expect("exact original continuation")
            .outcome,
        weaver_contracts::PublicationOutcome::Committed
    );
    assert_eq!(
        registered(&reader),
        0,
        "late absence remains historical after commit"
    );
    weaver_ledger::persistence::script(&reader, "ROLLBACK;").expect("close old read snapshot");
    assert_eq!(
        registered(&reader),
        1,
        "fresh read sees inherited local registration"
    );
    drop(reader);
    assert!(
        ledger
            .dispatch_provider(&permit, || {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert!(ledger.complete_provider(&permit, "arrow").is_err());
    drop(old_worker);
    drop(ledger);
    let mut recovered = Ledger::open(&path).expect("process recovery");
    assert_eq!(
        recovered
            .publication_review(&key)
            .expect("registered artifact after restart"),
        Some(review)
    );
    assert!(recovered.register_approved_review(&replacement).is_err());
    assert!(
        recovered
            .dispatch_provider(&permit, || {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert!(
        recovered
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .is_err()
    );
    assert_eq!(recovered.held("f").expect("unknown budget remains held"), 4);
    let receipt = recovered
        .provider_receipt("f", "infer")
        .expect("unknown receipt")
        .expect("original run");
    assert_eq!(
        (receipt.state, receipt.reserved, receipt.held),
        (weaver_contracts::ProviderState::Unknown, 4, 4)
    );
    assert_eq!(
        calls, 1,
        "recovery cannot release the uncertain tail or repeat dispatch"
    );
    let inspection =
        weaver_ledger::persistence::Session::open(&path).expect("durable range inspection");
    let state: String = weaver_ledger::persistence::one(
        &inspection,
        "SELECT state FROM provider_releases WHERE family='f' AND node='infer'",
        (),
        |row| row.get(0),
    )
    .expect("original range");
    assert_eq!(state, "unknown");
}
#[test]
fn equal_batch_digests_cannot_transfer_release_between_original_nodes() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("provider.db");
    let (mut ledger, plan) = fixture_nodes(&path, &["infer", "second"]);
    let mut second = plan.clone();
    second.node = "second".into();
    let mut owners = Vec::new();
    for plan in [&plan, &second] {
        ledger.enqueue_provider(plan).expect("queue");
        let owner = ledger
            .consume_provider("f", &plan.node, &BTreeSet::from(["primary".into()]))
            .expect("consume");
        ledger
            .dispatch_provider(&owner, || Ok(()))
            .expect("dispatch");
        owners.push(owner);
    }
    let first_release = ledger
        .prepare_provider_release(&owners[0], "same-batch-digest", "arrow", 2)
        .expect("first release");
    let second_release = ledger
        .prepare_provider_release(&owners[1], "same-batch-digest", "arrow", 2)
        .expect("second release");
    let mut calls = 0;
    assert!(
        ledger
            .release_provider(&owners[1], first_release, "arrow", |_| {
                calls += 1;
                Ok(())
            })
            .is_err(),
        "foreign logical node admitted release"
    );
    assert_eq!(calls, 0);
    ledger
        .release_provider(&owners[1], second_release, "arrow", |first| {
            assert_eq!(first, 0);
            calls += 1;
            Ok(())
        })
        .expect("original second release");
    assert_eq!(calls, 1);
    assert!(
        ledger
            .prepare_provider_release(&owners[0], "same-batch-digest", "arrow", 2)
            .is_err(),
        "unknown first release must remain spent"
    );
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert_eq!(ledger.held("f").expect("shared hold"), 8);
    for owner in owners {
        assert!(
            ledger
                .consume_provider("f", &owner.plan().node, &BTreeSet::from(["primary".into()]))
                .is_err()
        );
    }
}
#[test]
fn release_encoding_cannot_change_after_preparation() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("provider.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("queue");
    let owner = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger
        .dispatch_provider(&owner, || Ok(()))
        .expect("dispatch");
    let release = ledger
        .prepare_provider_release(&owner, "same-batch-digest", "arrow", 1)
        .expect("release");
    let mut calls = 0;
    assert!(
        ledger
            .release_provider(&owner, release, "protobuf", |_| {
                calls += 1;
                Ok(())
            })
            .is_err(),
        "prepared encoding changed at final release"
    );
    assert_eq!(calls, 0);
    assert!(
        ledger
            .prepare_provider_release(&owner, "same-batch-digest", "arrow", 1)
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("hold"), 4);
}
#[test]
fn affine_provider_dispatch_and_revoked_batch_never_repeat_or_refund() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("provider.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("queue");
    let owner = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    assert!(
        ledger
            .prepare_provider_release(&owner, "digest", "arrow", 2)
            .is_err(),
        "no response before dispatch burn"
    );
    let mut calls = 0;
    ledger
        .dispatch_provider(&owner, || {
            calls += 1;
            Ok(())
        })
        .expect("dispatch");
    assert!(
        ledger
            .dispatch_provider(&owner, || {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(calls, 1);
    let release = ledger
        .prepare_provider_release(&owner, "digest", "arrow", 2)
        .expect("prepare batch");
    ledger
        .publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2)
        .expect("revoke");
    let mut releases = 0;
    assert!(
        ledger
            .release_provider(&owner, release, "arrow", |_| {
                releases += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(releases, 0);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(
        ledger
            .dispatch_provider(&owner, || {
                calls += 1;
                Ok(())
            })
            .is_err()
    );
    assert!(
        ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("held"), 4);
}
#[test]
fn historical_publication_replay_cannot_reopen_original_claim_or_dispatch() {
    for consumed in [false, true] {
        let temp = tempfile::tempdir().expect("temp");
        let path = temp.path().join("publication-join.db");
        let (mut ledger, plan) = fixture(&path);
        ledger.enqueue_provider(&plan).expect("reserve original");
        let targets = BTreeSet::from(["primary".into()]);
        let owner = consumed.then(|| {
            ledger
                .consume_provider("f", "infer", &targets)
                .expect("consume original")
        });
        let revoke = weaver_contracts::Publication {
            operation_id: "lost-revoke-reply".into(),
            expected_revision: Some(0),
            fence: 2,
            policy: "forbid(principal,action,resource);".into(),
            schema: SCHEMA.into(),
        };
        // The durable decision exists although the caller discards its response.
        let historical = ledger.publish_authority(&revoke).expect("commit revoke");
        let restore = weaver_contracts::Publication {
            operation_id: "later-restore".into(),
            expected_revision: Some(1),
            fence: 3,
            policy: POLICY.into(),
            schema: SCHEMA.into(),
        };
        ledger
            .publish_authority(&restore)
            .expect("advance current head");
        assert_eq!(
            ledger
                .publish_authority(&revoke)
                .expect("exact historical retry"),
            historical
        );
        let mut calls = 0;
        if let Some(permit) = &owner {
            assert!(
                ledger
                    .dispatch_provider(permit, || {
                        calls += 1;
                        Ok(())
                    })
                    .is_err()
            );
        }
        assert!(ledger.consume_provider("f", "infer", &targets).is_err());
        ledger.close().expect("close deciding connection");
        let mut recovered = Ledger::open(&path).expect("recover durable state");
        assert_eq!(
            recovered
                .publish_authority(&revoke)
                .expect("recover lost result"),
            historical
        );
        if let Some(permit) = &owner {
            assert!(
                recovered
                    .dispatch_provider(permit, || {
                        calls += 1;
                        Ok(())
                    })
                    .is_err()
            );
        }
        let mut rebound = plan.clone();
        rebound.revision = 2;
        rebound.fence = 3;
        let reconciled = recovered
            .enqueue_provider(&rebound)
            .expect("same original digest reconciles");
        assert_eq!(reconciled.digest, plan.digest().expect("original digest"));
        let refreshed = recovered.consume_provider("f", "infer", &targets);
        if consumed {
            assert!(
                refreshed.is_err(),
                "fresh authority cannot repeat consumption"
            );
        } else {
            // A still-queued operation can make progress only after fresh
            // authorization refreshes its observation coordinates under CAS.
            let fresh_owner = refreshed.expect("freshly authorized original claim");
            recovered
                .dispatch_provider(&fresh_owner, || {
                    calls += 1;
                    Ok(())
                })
                .expect("fresh send");
            assert!(
                recovered
                    .dispatch_provider(&fresh_owner, || {
                        calls += 1;
                        Ok(())
                    })
                    .is_err()
            );
        }
        rebound.node = "new-claim".into();
        assert!(recovered.enqueue_provider(&rebound).is_err());
        rebound.node = "infer".into();
        rebound.profile = "new-profile".into();
        assert!(recovered.enqueue_provider(&rebound).is_err());
        let connection =
            weaver_ledger::persistence::Session::open(&path).expect("inspect original task");
        let record: String = weaver_ledger::persistence::one(
            &connection,
            "SELECT record FROM tasks WHERE family='f'",
            (),
            |row| row.get(0),
        )
        .expect("task");
        let mut original: Task = serde_json::from_str(&record).expect("decode task");
        original.budget += 1;
        assert!(
            recovered.register_task(&original).is_err(),
            "restart cannot reset original budget"
        );
        assert_eq!(recovered.held("f").expect("original hold"), 4);
        assert_eq!(
            recovered
                .provider_receipt("f", "infer")
                .expect("history")
                .expect("original outcome")
                .state,
            weaver_contracts::ProviderState::Unknown
        );
        assert_eq!(calls, usize::from(!consumed));
        recovered.close().expect("close recovered connection");
    }
}

#[test]
fn final_release_keeps_current_guard_and_unknown_commit_in_one_transaction() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("release-order.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("reserve");
    let owner = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume original");
    ledger
        .dispatch_provider(&owner, || Ok(()))
        .expect("durable invocation burn");
    let release = ledger
        .prepare_provider_release(&owner, "release-digest", "arrow", 2)
        .expect("durable unknown range");
    let inspection =
        weaver_ledger::persistence::Session::open(&path).expect("independent observer");
    inspection
        .busy_timeout(std::time::Duration::ZERO)
        .expect("no waiting in negative control");
    let mut callbacks = 0;
    let result: weaver_contracts::Result<()> =
        ledger.release_provider(&owner, release, "arrow", |_| {
            callbacks += 1;
            let state: String = weaver_ledger::persistence::one(&inspection, "SELECT state FROM provider_releases WHERE family='f' AND node='infer'", (), |row| row.get(0))
                .expect("read already committed unknown range");
            assert_eq!(state, "unknown");
            let dispatched: i64 = weaver_ledger::persistence::one(&inspection, "SELECT dispatched FROM provider_runs WHERE family='f' AND node='infer'", (), |row| row.get(0))
                .expect("read already committed burn");
            assert_eq!(dispatched, 2, "guarded callback transaction is already durable");
            let (held, reserved, state): (i64, i64, String) = weaver_ledger::persistence::one(&inspection, "SELECT t.held,r.reserved,r.state FROM provider_runs r JOIN tasks t ON t.family=r.family WHERE r.family='f' AND r.node='infer'", (), |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?))).expect("durable consumed root and original reservation");
            assert_eq!((held, reserved, state.as_str()), (4, 4, "unknown"));
            let claim: String = weaver_ledger::persistence::one(&inspection, "SELECT kind FROM execution_claims WHERE family='f' AND node='infer'", (), |row| row.get(0)).expect("canonical original claim");
            assert_eq!(claim, "provider");
            let blocked =
                weaver_ledger::persistence::exec(&inspection, "UPDATE authority SET fence=fence+1 WHERE singleton=1", ());
            assert!(
                matches!(blocked, Err(weaver_ledger::persistence::Error::Busy(_) | weaver_ledger::persistence::Error::BusySnapshot(_)))
            );
            // The send callback may have exposed bytes; loss of its completion
            // observation must roll back only the release marker, never the hold.
            Err(weaver_contracts::Error::Conflict(
                "test lost completion observation",
            ))
        });
    assert!(result.is_err());
    assert_eq!(callbacks, 1);
    drop(inspection);
    ledger.close().expect("close failed release owner");
    let mut recovered = Ledger::open(&path).expect("recover");
    let receipt = recovered
        .provider_receipt("f", "infer")
        .expect("inspect")
        .expect("original");
    assert_eq!(receipt.events, 2);
    assert_eq!(receipt.held, 4);
    assert!(
        recovered
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .is_err()
    );
    assert!(
        recovered
            .dispatch_provider(&owner, || {
                callbacks += 1;
                Ok(())
            })
            .is_err()
    );
    assert_eq!(callbacks, 1);
    recovered.close().expect("close recovered owner");
}

#[test]
fn final_queue_rejects_mismatched_durable_range_before_callback() {
    for corruption in ["digest='wrong'", "length=2", "state='released'"] {
        let temp = tempfile::tempdir().expect("temp");
        let path = temp.path().join("mismatched-release.db");
        let storage = weaver_ledger::persistence::Session::open_with_journal(
            &path,
            weaver_ledger::persistence::Journal::Mvcc,
        )
        .expect("MVCC");
        let (mut ledger, plan) = fixture(&path);
        ledger.enqueue_provider(&plan).expect("reserve");
        let owner = ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .expect("consume");
        ledger
            .dispatch_provider(&owner, || Ok(()))
            .expect("dispatch");
        let range = ledger
            .prepare_provider_release(&owner, "digest", "protobuf", 1)
            .expect("reserve range");
        weaver_ledger::persistence::exec(
            &storage,
            &format!("UPDATE provider_releases SET {corruption}"),
            (),
        )
        .expect("inject stale durable range");
        let refused = ledger.release_provider::<()>(&owner, range, "protobuf", |_| {
            panic!("mismatched range reached the queue")
        });
        assert!(matches!(
            refused,
            Err(weaver_contracts::Error::Conflict(
                "provider release binding"
            ))
        ));
        let retained = ledger
            .provider_receipt("f", "infer")
            .expect("read")
            .expect("original");
        assert_eq!((retained.held, retained.events), (4, 1));
        assert_eq!(retained.state, weaver_contracts::ProviderState::Unknown);
    }
}

/// Expected coverage gap: typed, fenced publication is not a native
/// Authorization Delta/no-gain evidence admission protocol.
#[test]
fn typed_publication_does_not_yet_require_delta_evidence() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("delta-publication-gap.db");
    let (mut ledger, plan) = fixture(&path);
    let inspection =
        weaver_ledger::persistence::Session::open(&path).expect("inspect original task");
    let record: String = weaver_ledger::persistence::one(
        &inspection,
        "SELECT record FROM tasks WHERE family='f'",
        (),
        |row| row.get(0),
    )
    .expect("original task record");
    let task: Task = serde_json::from_str(&record).expect("typed original task");
    let binding =
        weaver_policy::bind_provider(&task, &plan, &plan.routes[0]).expect("actual binding");
    let denied = "forbid(principal,action,resource);";
    assert!(
        binding
            .authorize(
                denied,
                weaver_policy::ProviderCheck {
                    action: "invokeProvider",
                    sequence: 0,
                    format: "protobuf",
                    domains: None,
                }
            )
            .is_err()
    );
    assert!(
        binding
            .authorize(
                POLICY,
                weaver_policy::ProviderCheck {
                    action: "invokeProvider",
                    sequence: 0,
                    format: "protobuf",
                    domains: None,
                }
            )
            .is_ok()
    );
    for (id, expected, fence, policy) in [
        ("deny-before-delta-review", 0, 2, denied),
        ("allow-without-delta-evidence", 1, 3, POLICY),
    ] {
        let change = weaver_contracts::Publication {
            operation_id: id.into(),
            expected_revision: Some(expected),
            fence,
            policy: policy.into(),
            schema: SCHEMA.into(),
        };
        ledger
            .stage_authority(&change)
            .expect("durable proposal barrier");
        let outcome = ledger
            .publish_authority(&change)
            .expect("typed publication accepts the source command");
        assert_eq!(
            outcome.outcome,
            weaver_contracts::PublicationOutcome::Committed
        );
    }
    drop(inspection);
    ledger.close().expect("close gap fixture");
}

/// Expected counterexample: FULL WAL durability does not authenticate freshness
/// of an externally restored, internally consistent database image.
#[test]
fn whole_database_rollback_requires_an_independent_recovery_floor() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("live.db");
    let snapshot = temp.path().join("before-consumption.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("queue original");
    ledger
        .close()
        .expect("checkpoint and close before snapshot");
    crate::snapshot::copy_closed(&path, &snapshot).expect("copy closed database");
    let targets = BTreeSet::from(["primary".into()]);
    let mut external_calls = 0_u64;
    for restore in [false, true, true] {
        if restore {
            crate::snapshot::copy_closed(&snapshot, &path)
                .expect("restore closed database snapshot");
        }
        let mut owner = Ledger::open(&path).expect("new owner session");
        let permit = owner
            .consume_provider("f", "infer", &targets)
            .expect("consume restored queued state");
        owner
            .dispatch_provider(&permit, || {
                external_calls += 1;
                Ok(())
            })
            .expect("external effect");
        assert_eq!(owner.held("f").expect("one restored hold"), 4);
        owner.close().expect("close before next image replacement");
    }
    // This is an unqualified threat boundary, not an accepted production result.
    // Fresh process/session identity alone cannot detect a whole-store rollback.
    assert_eq!(external_calls, 3);
    let inspection =
        weaver_ledger::persistence::Session::open(&path).expect("inspect restored budget");
    let budget: i64 = weaver_ledger::persistence::one(
        &inspection,
        "SELECT budget FROM tasks WHERE family='f'",
        (),
        |row| row.get(0),
    )
    .expect("original budget");
    assert!(
        external_calls * plan.ceiling > u64::try_from(budget).expect("nonnegative account budget"),
        "possible external exposure exceeds the original account ceiling"
    );
    inspection.close().expect("close inspection");
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn release_capabilities_bind_plan_encoding_and_restart_session(
        rows in 1u64..33, prepared_arrow in proptest::bool::ANY,
        requested_arrow in proptest::bool::ANY, foreign_plan in proptest::bool::ANY,
        restart in proptest::bool::ANY,
    ) {
        let temp = tempfile::tempdir().expect("temp");
        let path = temp.path().join("provider.db");
        let (mut ledger, plan) = fixture_nodes(&path, &["infer", "second"]);
        let mut second = plan.clone();
        second.node = "second".into();
        let mut owners = Vec::new();
        for original in [&plan, &second] {
            ledger.enqueue_provider(original).expect("queue");
            let owner = ledger.consume_provider("f", &original.node, &BTreeSet::from(["primary".into()])).expect("consume");
            ledger.dispatch_provider(&owner, || Ok(())).expect("dispatch");
            owners.push(owner);
        }
        let prepared = if prepared_arrow {"arrow"} else {"protobuf"};
        let requested = if requested_arrow {"arrow"} else {"protobuf"};
        let first = ledger.prepare_provider_release(&owners[0], "same-batch", prepared, rows).expect("first release");
        let _second = ledger.prepare_provider_release(&owners[1], "same-batch", requested, rows).expect("second release");
        if restart {
            drop(ledger);
            ledger = Ledger::open(&path).expect("restart");
        }
        let mut calls = 0;
        let result = ledger.release_provider(&owners[usize::from(foreign_plan)], first, requested, |_| {calls += 1; Ok(())});
        let expected = !foreign_plan && !restart && prepared_arrow == requested_arrow;
        prop_assert_eq!(result.is_ok(), expected);
        prop_assert_eq!(calls, usize::from(expected));
        prop_assert_eq!(ledger.held("f").expect("shared hold"), 8);
    }
    #[test]
    fn arbitrary_provider_replays_restarts_and_release_batches_keep_original_claim(events in proptest::collection::vec((0u8..8,1u64..4),1..40)) {
        let temp=tempfile::tempdir().expect("temp");let path=temp.path().join("provider.db");let(mut ledger,mut plan)=fixture(&path);
        let mut owner:Option<ProviderDispatch>=None;let mut release:Option<(ProviderRelease,u64)>=None;
        let mut admitted=false;let mut calls=0;let mut rows=BTreeSet::new();
        for(action,length)in events {
            match action {
                0=>{if ledger.enqueue_provider(&plan).is_ok(){admitted=true;}},
                1=>{if let Ok(permit)=ledger.consume_provider("f","infer",&BTreeSet::from(["primary".into()])){owner=Some(permit);}},
                2=>{if let Some(ref permit)=owner {let _=ledger.dispatch_provider(permit,||{ calls+=1; Ok(()) });}},
                3=>{if release.is_none() && let Some(ref permit)=owner && let Ok(r)=ledger.prepare_provider_release(permit,"batch-digest","arrow",length){release=Some((r,length));}},
                4=>{if let (Some(permit),Some((r,count)))=(owner.as_ref(),release.take()){let _=ledger.release_provider(permit,r,"arrow",|start|{for row in start..start+count {assert!(rows.insert(row),"repeated logical response row");}Ok(())});}},
                5=>{drop(ledger);ledger=Ledger::open(&path).expect("restart");},
                6=>{plan.revision=ledger.publish_typed(Some(plan.revision),POLICY,SCHEMA,plan.fence+1).expect("publish");plan.fence+=1;},
                _=>{let mut forged=plan.clone();forged.profile="forged".into();prop_assert!(ledger.enqueue_provider(&forged).is_err());},
            }
            prop_assert!(calls<=1);prop_assert_eq!(ledger.held("f").expect("held"),if admitted {4}else{0});
        }
    }
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn balanced_provider_projection_never_funds_a_different_original_plan(
        original in 5u64..8, restart in proptest::bool::ANY
    ) {
        let temp=tempfile::tempdir().expect("directory");
        let path=temp.path().join("balanced-provider.db");
        let (mut ledger,plan)=fixture_with_ceiling(&path,&["infer","second"],original);
        ledger.enqueue_provider(&plan).expect("original hold");
        let permit=ledger.consume_provider("f","infer",&BTreeSet::from(["primary".into()])).expect("unknown original");
        drop(permit);
        let connection=weaver_ledger::persistence::Session::open(&path).expect("fault writer");
        weaver_ledger::persistence::script(&connection, "BEGIN IMMEDIATE; UPDATE provider_runs SET reserved=1 WHERE node='infer'; UPDATE tasks SET held=1; COMMIT;").expect("balanced incomplete recovery");
        drop(connection);
        if restart {drop(ledger);ledger=Ledger::open(&path).expect("restart");}
        let mut second=plan.clone();second.node="second".into();
        prop_assert!(ledger.enqueue_provider(&second).is_err());
        prop_assert!(ledger.provider_receipt("f","second").expect("observation").is_none());
        prop_assert_eq!(ledger.held("f").expect("unchanged projection"),1);
    }
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn lost_provider_reservation_row_keeps_orphaned_claim_budget_blocked(original in 5u64..8, restart in proptest::bool::ANY) {
        let temp=tempfile::tempdir().expect("directory");let path=temp.path().join("orphaned-provider.db");
        let (mut ledger,plan)=fixture_with_ceiling(&path,&["infer","second"],original);
        ledger.enqueue_provider(&plan).expect("original hold");
        drop(ledger.consume_provider("f","infer",&BTreeSet::from(["primary".into()])).expect("unknown original"));
        let connection=weaver_ledger::persistence::Session::open(&path).expect("fault writer");
        weaver_ledger::persistence::script(&connection, "BEGIN IMMEDIATE; DELETE FROM provider_runs; UPDATE tasks SET held=0; COMMIT;").expect("lost reservation and aggregate");drop(connection);
        if restart {drop(ledger);ledger=Ledger::open(&path).expect("restart");}
        let mut second=plan.clone();second.node="second".into();
        prop_assert!(ledger.enqueue_provider(&second).is_err());
        prop_assert!(ledger.provider_receipt("f","second").expect("observe").is_none());
        prop_assert_eq!(ledger.held("f").expect("unrepaired projection"),0);
    }
}

proptest! {
    #![proptest_config(Config::with_cases(48))]
    #[test]
    fn transaction_local_batch_reads_preserve_every_row_and_unknown_exposure(
        length in 1u64..33, denied in 0u64..32, fault in 0u8..7, mvcc in proptest::bool::ANY
    ) {
        let temp = tempfile::tempdir().expect("batch directory");
        let path = temp.path().join("batch.db");
        let storage = weaver_ledger::persistence::Session::open_with_journal(&path,
            if mvcc {weaver_ledger::persistence::Journal::Mvcc} else {weaver_ledger::persistence::Journal::Wal}).expect("journal");
        let (mut ledger, mut plan) = fixture(&path);
        let restricted = format!("{POLICY} forbid(principal, action == Weaver::Action::\"emitProvider\", resource) when {{ context.sequence == {} }};",denied % length);
        ledger.publish_typed(Some(0),if fault==1 {&restricted} else {POLICY},SCHEMA,1).expect("source contract");
        plan.revision=1;
        ledger.enqueue_provider(&plan).expect("reservation");
        let eligible=BTreeSet::from(["primary".into()]);
        let permit=ledger.consume_provider("f","infer",&eligible).expect("consume");
        ledger.dispatch_provider(&permit,||Ok(())).expect("request burn");
        let prepared=ledger.prepare_provider_release(&permit,"bounded-batch","arrow",length);
        if fault==1 {
            prop_assert!(prepared.is_err(),"an interior denied row admitted the batch");
        } else {
            let release=prepared.expect("original release burn");
            match fault {
                2 => {weaver_ledger::persistence::exec(&storage,"UPDATE authority SET policy=?1",[restricted.as_str()]).expect("fault: changed source without version advance");},
                3 => {ledger.publish_typed(Some(1),POLICY,SCHEMA,2).expect("new fence after preparation");},
                4 => {weaver_ledger::persistence::exec(&storage,"DELETE FROM execution_claims WHERE family='f'",()).expect("fault: missing original claim");},
                5 => {weaver_ledger::persistence::exec(&storage,"DELETE FROM domain_history",()).expect("fault: missing history");},
                _ => {}
            }
            let calls=Cell::new(0);
            let result=ledger.release_provider(&permit,release,"arrow",|first|{
                calls.set(calls.get()+1);
                assert_eq!(first,0,"original batch interval");
                if fault==6 {Err(weaver_contracts::Error::Conflict("lost queue observation"))}else{Ok(())}
            });
            prop_assert_eq!(result.is_ok(),fault==0);
            prop_assert_eq!(calls.get(),if fault==0||fault==6 {1} else {0});
            if fault!=0 {
                prop_assert!(ledger.prepare_provider_release(&permit,"replacement","arrow",1).is_err(),"unknown release reconstructed");
            }
        }
        prop_assert_eq!(ledger.held("f").expect("retained hold"),4);
        prop_assert!(ledger.consume_provider("f","infer",&eligible).is_err(),"consumed request reconstructed");
        drop(ledger);
        storage.close().expect("natural storage drain");
        let recovery=weaver_ledger::persistence::Session::open_with_journal(&path,
            if mvcc {weaver_ledger::persistence::Journal::Mvcc} else {weaver_ledger::persistence::Journal::Wal}).expect("same explicit recovery profile");
        let mut recovered=Ledger::open(&path).expect("fresh worker");
        prop_assert_eq!(recovered.held("f").expect("durable hold"),4);
        prop_assert!(recovered.consume_provider("f","infer",&eligible).is_err(),"restart reconstructed send");
        recovered.close().expect("recovery drain");
        recovery.close().expect("recovery owner drain");
    }
}
