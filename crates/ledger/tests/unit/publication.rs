// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use crate::{Ledger, store::integer};
use std::sync::{Arc, Barrier};
use weaver_contracts::PublicationOutcome::{Committed, Rejected};
use weaver_contracts::{Publication, PublicationKey};
const POLICY: &str = include_str!("../../../../prod/policies/provider/provider.cedar");
const SCHEMA: &str = include_str!("../../../../prod/policies/provider/schema.json");
fn change(id: &str, expected: Option<u64>) -> Publication {
    Publication {
        operation_id: id.into(),
        expected_revision: expected,
        fence: 1,
        policy: POLICY.into(),
        schema: SCHEMA.into(),
    }
}

#[test]
fn decision_failure_retains_pending_policy_until_the_same_atomic_outcome_commits() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("pending.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let original = change("pending", None);
    let key = ledger.stage_authority(&original).expect("durable stage");
    weaver_ledger::persistence::script(&ledger.connection, "CREATE TRIGGER deny_decision BEFORE INSERT ON authority_publications BEGIN SELECT RAISE(ABORT,'injected decision failure'); END;").expect("fault");
    assert!(ledger.publish_authority(&original).is_err());
    assert!(ledger.publication_receipt(&key).expect("lookup").is_none());
    assert!(crate::publication_barrier::require_resolved(&ledger.connection).is_err());
    let head: bool = weaver_ledger::persistence::one(
        &ledger.connection,
        "SELECT EXISTS(SELECT 1 FROM authority)",
        (),
        |row| row.get(0),
    )
    .expect("head");
    assert!(!head, "failed decision partially activated its Policy");
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    weaver_ledger::persistence::script(&ledger.connection, "DROP TRIGGER deny_decision")
        .expect("recover storage");
    assert_eq!(ledger.stage_authority(&original).expect("same stage"), key);
    assert_eq!(
        ledger
            .publish_authority(&original)
            .expect("same decision")
            .outcome,
        Committed
    );
    crate::publication_barrier::require_resolved(&ledger.connection).expect("resolved");
}

#[test]
fn concurrent_stage_and_finalize_cannot_resurrect_a_decided_barrier() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("race.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let original = change("race", None);
    ledger.stage_authority(&original).expect("stage");
    let gate = Arc::new(Barrier::new(2));
    let child_gate = gate.clone();
    let child_path = path.clone();
    let child_change = original.clone();
    let stage = std::thread::spawn(move || {
        let mut old_worker = Ledger::open(child_path).expect("second handle");
        child_gate.wait();
        old_worker
            .stage_authority(&child_change)
            .expect("late stage")
    });
    gate.wait();
    let decided = ledger.publish_authority(&original).expect("final CAS");
    assert_eq!(stage.join().expect("worker").digest, decided.digest);
    crate::publication_barrier::require_resolved(&ledger.connection)
        .expect("late stage cannot reopen pending");
}
#[test]
fn historical_decisions_survive_restart_and_cannot_rebase_or_replace_original_id() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("store.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let first = change("first", None);
    let original = ledger.publish_authority(&first).expect("commit");
    assert_eq!(original.outcome, Committed);
    let rejected = ledger
        .publish_authority(&change("stale", None))
        .expect("durable rejection");
    assert_eq!(rejected.outcome, Rejected);
    let next = change("next", Some(0));
    assert_eq!(
        ledger.publish_authority(&next).expect("next").revision,
        Some(1)
    );
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("reopen");
    assert_eq!(
        ledger.publish_authority(&first).expect("lost reply replay"),
        original
    );
    assert_eq!(
        ledger
            .publish_authority(&change("stale", None))
            .expect("same rejected"),
        rejected
    );
    let mut rebound = first.clone();
    rebound.expected_revision = Some(1);
    assert!(ledger.publish_authority(&rebound).is_err());
    assert!(
        ledger
            .publication_receipt(&PublicationKey {
                operation_id: "first".into(),
                digest: next.digest().expect("digest")
            })
            .is_err()
    );
    assert!(
        ledger
            .publication_receipt(&PublicationKey {
                operation_id: "missing".into(),
                digest: first.digest().expect("digest")
            })
            .expect("absence")
            .is_none()
    );
    let current: u64 = weaver_ledger::persistence::one(
        &ledger.connection,
        "SELECT revision FROM authority",
        (),
        |r| integer(r, 0),
    )
    .expect("head");
    assert_eq!(current, 1);
}
#[test]
fn outcome_insert_failure_rolls_back_policy_schema_and_result_together() {
    let temp = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(temp.path().join("store.db")).expect("ledger");
    weaver_ledger::persistence::script(&ledger.connection, "CREATE TRIGGER fail_publication BEFORE INSERT ON authority_publications BEGIN SELECT RAISE(ABORT,'injected outcome failure'); END;").expect("fault");
    let proposal = change("atomic", None);
    assert!(ledger.publish_authority(&proposal).is_err());
    for table in ["authority", "authority_schema", "authority_publications"] {
        let count: u64 = weaver_ledger::persistence::one(
            &ledger.connection,
            &format!("SELECT count(*) FROM {table}"),
            (),
            |r| integer(r, 0),
        )
        .expect("count");
        assert_eq!(count, 0);
    }
    weaver_ledger::persistence::script(&ledger.connection, "DROP TRIGGER fail_publication")
        .expect("repair");
    assert_eq!(
        ledger
            .publish_authority(&proposal)
            .expect("retry same request")
            .outcome,
        Committed
    );
}
#[test]
fn concurrent_publications_serialize_one_winner_and_one_stable_conflict() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("store.db");
    let barrier = Arc::new(Barrier::new(2));
    let mut jobs = Vec::new();
    for id in ["left", "right"] {
        let mut ledger = Ledger::open(&path).expect("open");
        let gate = barrier.clone();
        jobs.push(std::thread::spawn(move || {
            gate.wait();
            ledger
                .publish_authority(&change(id, None))
                .expect("decision")
        }));
    }
    let outcomes: Vec<_> = jobs
        .into_iter()
        .map(|job| job.join().expect("worker"))
        .collect();
    assert_eq!(
        outcomes.iter().filter(|r| r.outcome == Committed).count(),
        1
    );
    assert_eq!(outcomes.iter().filter(|r| r.outcome == Rejected).count(), 1);
    let mut ledger = Ledger::open(&path).expect("recover");
    for receipt in outcomes {
        assert_eq!(
            ledger
                .publish_authority(&change(&receipt.operation_id, None))
                .expect("replay"),
            receipt
        );
    }
}
#[test]
fn concurrent_same_identity_commits_only_one_revision() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("store.db");
    let barrier = Arc::new(Barrier::new(2));
    let mut jobs = Vec::new();
    for _ in 0..2 {
        let mut ledger = Ledger::open(&path).expect("open");
        let gate = barrier.clone();
        jobs.push(std::thread::spawn(move || {
            gate.wait();
            ledger
                .publish_authority(&change("same", None))
                .expect("decision")
        }));
    }
    let first = jobs.remove(0).join().expect("first");
    let second = jobs.remove(0).join().expect("second");
    assert_eq!(first, second);
    assert_eq!(first.outcome, Committed);
    assert_eq!(first.revision, Some(0));
    let ledger = Ledger::open(&path).expect("reopen");
    let count: u64 = weaver_ledger::persistence::one(
        &ledger.connection,
        "SELECT count(*) FROM authority_publications",
        (),
        |r| integer(r, 0),
    )
    .expect("count");
    assert_eq!(count, 1);
}
#[test]
fn connection_reuse_rejects_an_unresolved_explicit_transaction() {
    let temp = tempfile::tempdir().expect("directory");
    let ledger = Ledger::open(temp.path().join("store.db")).expect("ledger");
    ledger.require_quiescent().expect("initial quiescence");
    weaver_ledger::persistence::script(&ledger.connection, "BEGIN IMMEDIATE")
        .expect("injected unresolved transaction");
    assert!(ledger.require_quiescent().is_err());
    weaver_ledger::persistence::script(&ledger.connection, "ROLLBACK").expect("rollback");
    ledger.require_quiescent().expect("resolved");
}
proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(64))]
    #[test]
    fn arbitrary_replay_restart_and_late_observation_schedules_keep_decisions(
        actions in proptest::collection::vec(0u8..4,1..32)
    ) {
        let temp=tempfile::tempdir().expect("directory");let path=temp.path().join("store.db");
        let mut ledger=Ledger::open(&path).expect("open");let proposal=change("original",None);
        let receipt=ledger.publish_authority(&proposal).expect("commit");
        for action in actions {
            match action {
                0=>{drop(ledger);ledger=Ledger::open(&path).expect("restart");},
                1=>assert_eq!(ledger.publish_authority(&proposal).expect("same retry"),receipt),
                2=>assert_eq!(ledger.publication_receipt(&PublicationKey{operation_id:"original".into(),digest:proposal.digest().expect("digest")}).expect("observe"),Some(receipt.clone())),
                _=>{let mut forged=proposal.clone();forged.fence=2;assert!(ledger.publish_authority(&forged).is_err());},
            }
        }
    }
}
