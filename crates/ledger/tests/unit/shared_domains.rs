// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::fixtures::{POLICY, proposal, task};
use proptest::{prop_assert_eq, proptest, test_runner::Config as ProptestConfig};
use weaver_contracts::{DomainBinding, DomainMigration};
use weaver_ledger::{
    Ledger,
    persistence::{Journal, Session},
};

fn register(
    ledger: &mut Ledger,
    family: &str,
    origin: &str,
    budget: &str,
    history: &str,
    cap: u64,
) {
    let mut t = task();
    t.family = family.into();
    ledger
        .register_task_domains(
            &t,
            &DomainBinding {
                origin: origin.into(),
                budget: budget.into(),
                history: history.into(),
                budget_limit: cap,
            },
            None,
        )
        .expect("source binding");
}
fn reserve(
    ledger: &mut Ledger,
    family: &str,
    node: u8,
    cap: u64,
) -> weaver_contracts::Result<weaver_contracts::Receipt> {
    let mut p = proposal(node, cap);
    p.family = family.into();
    ledger.enqueue(&p)
}
fn merge(id: &str, a: &str, b: &str) -> DomainMigration {
    DomainMigration {
        operation_id: id.into(),
        budget_from: a.into(),
        budget_to: b.into(),
        history_from: a.into(),
        history_to: b.into(),
        budget_from_epoch: 1,
        budget_to_epoch: 1,
        history_from_epoch: 1,
        history_to_epoch: 1,
    }
}
#[test]
fn shared_domains_keep_original_origin_and_unknown_exposure_across_restart() {
    let d = tempfile::tempdir().expect("authoritative test state");
    let path = d.path().join("origins.db");
    let mut l = Ledger::open(&path).expect("authoritative test state");
    l.publish(None, POLICY, 1)
        .expect("authoritative test state");
    register(&mut l, "a", "origin-a", "shared", "shared", 8);
    register(&mut l, "b", "origin-b", "shared", "shared", 8);
    reserve(&mut l, "a", 0, 4).expect("authoritative test state");
    reserve(&mut l, "b", 0, 4).expect("authoritative test state");
    let permit = l.consume("a", "n0").expect("authoritative test state");
    let alias = l
        .register_family_alias("reconnect", "origin-a")
        .expect("authoritative test state");
    assert_eq!(alias.canonical_family, "a");
    assert_eq!(alias.held, 8);
    let mut replacement = task();
    replacement.family = "reconnect".into();
    assert!(l.register_task(&replacement).is_err());
    replacement.family = "new-family".into();
    assert!(
        l.register_task_domains(
            &replacement,
            &DomainBinding {
                origin: "origin-a".into(),
                budget: "new".into(),
                history: "new".into(),
                budget_limit: 20
            },
            None
        )
        .is_err()
    );
    assert!(reserve(&mut l, "reconnect", 0, 1).is_err());
    assert!(reserve(&mut l, "b", 1, 1).is_err());
    drop(l);
    let mut recovered = Ledger::open(&path).expect("authoritative test state");
    assert!(
        recovered
            .dispatch(permit, |_| panic!("old worker sent"))
            .is_err()
    );
    assert!(recovered.consume("a", "n0").is_err());
    assert_eq!(
        recovered
            .execution_domains("b")
            .expect("authoritative test state")
            .history_count,
        2
    );
    assert_eq!(
        recovered
            .execution_domains("a")
            .expect("authoritative test state")
            .held,
        8
    );
}
#[test]
fn union_fences_live_permits_and_lost_reply_replays_the_original_decision() {
    let d = tempfile::tempdir().expect("authoritative test state");
    let path = d.path().join("merge.db");
    let mut l = Ledger::open(&path).expect("authoritative test state");
    l.publish(None, POLICY, 1)
        .expect("authoritative test state");
    register(&mut l, "a", "oa", "a", "a", 12);
    register(&mut l, "sibling", "os", "a", "a", 12);
    register(&mut l, "b", "ob", "b", "b", 10);
    reserve(&mut l, "a", 0, 3).expect("authoritative test state");
    reserve(&mut l, "sibling", 0, 2).expect("authoritative test state");
    reserve(&mut l, "b", 0, 3).expect("authoritative test state");
    let permit = l.consume("a", "n0").expect("authoritative test state");
    let command = merge("merge-ab", "a", "b");
    let committed = l
        .migrate_execution_domains(&command)
        .expect("authoritative test state");
    assert!(committed.committed);
    assert!(
        l.dispatch(permit, |_| panic!("pre-migration handle sent"))
            .is_err()
    );
    assert_eq!(
        l.execution_domains("sibling")
            .expect("authoritative test state")
            .stamp
            .budget_root,
        "b"
    );
    drop(l);
    let mut l = Ledger::open(&path).expect("authoritative test state");
    assert_eq!(
        l.migrate_execution_domains(&command)
            .expect("authoritative test state"),
        committed
    );
    let mut conflicting = command.clone();
    conflicting.budget_from_epoch = 2;
    assert!(l.migrate_execution_domains(&conflicting).is_err());
    register(&mut l, "late", "ol", "a", "a", 12);
    let view = l
        .execution_domains("late")
        .expect("authoritative test state");
    assert_eq!(
        (view.held, view.budget_limit, view.history_count),
        (8, 10, 3)
    );
    assert_eq!(view.stamp.budget_root, "b");
    assert!(reserve(&mut l, "late", 0, 3).is_err());
    assert_eq!(
        l.lookup("a", "n0")
            .expect("authoritative test state")
            .expect("authoritative test state")
            .outcome,
        weaver_contracts::Outcome::Unknown
    );
}
#[test]
fn rejected_union_is_durable_and_cannot_release_unknown_holds() {
    let d = tempfile::tempdir().expect("authoritative test state");
    let mut l = Ledger::open(d.path().join("reject.db")).expect("authoritative test state");
    l.publish(None, POLICY, 1)
        .expect("authoritative test state");
    register(&mut l, "a", "oa", "a", "a", 8);
    register(&mut l, "b", "ob", "b", "b", 8);
    reserve(&mut l, "a", 0, 5).expect("authoritative test state");
    reserve(&mut l, "b", 0, 5).expect("authoritative test state");
    let command = merge("too-large", "a", "b");
    let r = l
        .migrate_execution_domains(&command)
        .expect("authoritative test state");
    assert!(!r.committed);
    assert_eq!(
        l.migrate_execution_domains(&command)
            .expect("authoritative test state"),
        r
    );
    assert_eq!(
        l.execution_domains("a")
            .expect("authoritative test state")
            .held,
        5
    );
    assert_eq!(
        l.execution_domains("b")
            .expect("authoritative test state")
            .held,
        5
    );
}
proptest! {
    #![proptest_config(ProptestConfig::with_cases(32))]
    #[test]
    fn finite_families_never_split_a_shared_cap(costs in proptest::collection::vec(1u64..8,2..7),cap in 2u64..20) {
        let d=tempfile::tempdir().expect("authoritative test state");let path=d.path().join("pbt.db");
        let owner=Session::open_with_journal(&path,Journal::Mvcc).expect("authoritative test state");
        let mut l=Ledger::open(&path).expect("authoritative test state");l.publish(None,POLICY,1).expect("authoritative test state");
        let mut expected=0;
        for (index,cost) in costs.iter().enumerate() {
            let family=format!("f{index}");register(&mut l,&family,&format!("o{index}"),"budget","history",cap);
            let result=reserve(&mut l,&family,0,*cost);
            prop_assert_eq!(result.is_ok(),expected+cost<=cap);
            if result.is_ok(){expected+=cost;}
            prop_assert_eq!(l.execution_domains(&family).expect("authoritative test state").held,expected);
        }
        drop(l);let recovered=Ledger::open(&path).expect("authoritative test state");
        prop_assert_eq!(recovered.execution_domains("f0").expect("authoritative test state").held,expected);
        drop(recovered);owner.close().expect("authoritative test state");
    }
}

#[test]
fn equal_history_counts_cannot_mask_a_replaced_original_event() {
    let d = tempfile::tempdir().expect("directory");
    let path = d.path().join("history.db");
    let mut l = Ledger::open(&path).expect("ledger");
    l.publish(None, POLICY, 1).expect("policy");
    register(&mut l, "a", "oa", "shared", "shared", 8);
    register(&mut l, "b", "ob", "shared", "shared", 8);
    reserve(&mut l, "a", 0, 4).expect("original reserve");
    let permit = l.consume("a", "n0").expect("durable consumption");
    let connection = Session::open(&path).expect("fault connection");
    weaver_ledger::persistence::exec(
        &connection,
        "UPDATE domain_history SET digest='replacement' WHERE origin='oa'",
        (),
    )
    .expect("partial recovery fault");
    assert!(
        l.dispatch(permit, |_| panic!("history substitution authorized bytes"))
            .is_err()
    );
    assert!(reserve(&mut l, "b", 0, 4).is_err());
    assert_eq!(l.held("a").expect("original unknown exposure"), 4);
}

#[test]
fn migration_fences_consumed_range_and_retains_unknown_message() {
    let d = tempfile::tempdir().expect("directory");
    let path = d.path().join("range.db");
    let (mut ledger, contract) = super::stream_properties::fixture(&path);
    register(&mut ledger, "other", "other", "other", "other", 8);
    ledger
        .enqueue_message(&super::stream_properties::message(&contract, 0, 0, 1))
        .expect("message");
    let owner = ledger
        .claim_stream(weaver_ledger::StreamClaim {
            family: "f",
            node: "emit",
            destination: &contract.destination,
            revision: 0,
            fence: 1,
        })
        .expect("stream owner");
    let permit = ledger
        .consume_range(&owner, "m0", 4)
        .expect("range consumption");
    assert!(
        ledger
            .migrate_execution_domains(&merge("stream-union", "f", "other"))
            .expect("migration")
            .committed
    );
    assert!(
        ledger
            .write_range(&owner, permit, |_| panic!("old range reached transport"))
            .is_err()
    );
    assert!(ledger.consume_range(&owner, "m0", 4).is_err());
    assert_eq!(ledger.execution_domains("f").expect("merged hold").held, 4);
    drop(ledger);
    let mut recovered = Ledger::open(&path).expect("restart");
    assert!(
        recovered
            .claim_stream(weaver_ledger::StreamClaim {
                family: "f",
                node: "emit",
                destination: &contract.destination,
                revision: 0,
                fence: 1
            })
            .is_err()
    );
}
