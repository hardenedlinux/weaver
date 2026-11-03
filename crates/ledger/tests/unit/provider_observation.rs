// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Native callback/observation uncertainty retains the original claim and hold.
use super::{POLICY, SCHEMA, fixture};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::collections::BTreeSet;
use weaver_ledger::Ledger;

proptest! {
    #![proptest_config(Config::with_cases(16))]
    #[test]
    fn mvcc_effect_before_failed_observation_never_releases_or_replays(lost_callback: bool) {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("post-effect.db");
        let storage = weaver_ledger::persistence::Session::open_with_journal(&path, weaver_ledger::persistence::Journal::Mvcc).expect("MVCC");
        let (mut ledger, plan) = fixture(&path);
        ledger.enqueue_provider(&plan).expect("queue");
        let permit = ledger.consume_provider("f", "infer", &BTreeSet::from(["primary".into()])).expect("consume");
        ledger.dispatch_provider(&permit, || Ok(())).expect("original dispatch");
        let release = ledger.prepare_provider_release(&permit, "original-event", "protobuf", 1).expect("durable release burn");
        if !lost_callback {
            weaver_ledger::persistence::script(&storage,"CREATE TRIGGER fail_final_ack BEFORE UPDATE ON provider_releases WHEN NEW.state='released' BEGIN SELECT RAISE(ABORT,'injected post-effect observation failure'); END;").expect("fault after possible bytes");
        }
        let mut calls = 0;
        let result = ledger.release_provider(&permit,release,"protobuf", |_| {
            calls += 1;
            if lost_callback { Err(weaver_contracts::Error::Conflict("lost write response")) } else { Ok(()) }
        });
        prop_assert!(result.is_err()); prop_assert_eq!(calls,1);
        prop_assert_eq!(ledger.held("f").expect("held"),4);
        prop_assert!(ledger.prepare_provider_release(&permit,"new-event","protobuf",1).is_err());
        drop(ledger); storage.close().expect("owner drain");
        let storage = weaver_ledger::persistence::Session::open_with_journal(&path,weaver_ledger::persistence::Journal::Mvcc).expect("recovery");
        let mut recovered = Ledger::open(&path).expect("new worker");
        recovered.publish_typed(Some(0),POLICY,SCHEMA,2).expect("new authority cannot unspend");
        prop_assert!(recovered.consume_provider("f","infer",&BTreeSet::from(["primary".into()])).is_err());
        prop_assert_eq!(recovered.held("f").expect("original exposure"),4);
        drop(recovered); storage.close().expect("clean close");
    }
}

proptest! {
    #![proptest_config(Config::with_cases(16))]
    #[test]
    fn failed_callback_never_enters_final_commit_and_retains_original_exposure(mvcc: bool, possible_effect: bool) {
        let directory=tempfile::tempdir().expect("store");
        let path=directory.path().join("unsealed.db");
        let journal=if mvcc {weaver_ledger::persistence::Journal::Mvcc}else{weaver_ledger::persistence::Journal::Wal};
        let storage=weaver_ledger::persistence::Session::open_with_journal(&path,journal).expect("owner");
        let (mut ledger,plan)=fixture(&path);
        ledger.enqueue_provider(&plan).expect("original reservation");
        let eligible=BTreeSet::from(["primary".into()]);
        let permit=ledger.consume_provider("f","infer",&eligible).expect("consume");
        let before=ledger.transaction_timings();
        let mut calls=0;
        let failed:weaver_contracts::Result<()>=ledger.dispatch_provider(&permit,||{
            if possible_effect { calls+=1; }
            Err(weaver_contracts::Error::Conflict("callback failed without seal"))
        });
        prop_assert!(failed.is_err());
        prop_assert_eq!(ledger.transaction_timings().commit.attempts,before.commit.attempts+1,"only the earlier affine burn may commit");
        prop_assert_eq!(ledger.transaction_timings().rollback.attempts,before.rollback.attempts+1);
        let marker:i64=weaver_ledger::persistence::one(&storage,"SELECT dispatched FROM provider_runs WHERE family='f' AND node='infer'",(),|r|r.get(0)).expect("native retained burn");
        prop_assert_eq!(marker,1,"failed callback cannot record successful completion");
        prop_assert_eq!(ledger.held("f").expect("original hold"),4);
        prop_assert!(ledger.dispatch_provider(&permit,||{calls+=1;Ok(())}).is_err(),"spent original callback cannot repeat");
        prop_assert_eq!(calls,usize::from(possible_effect));
        ledger.close().expect("normal rollback drains");
        let mut recovered=Ledger::open(&path).expect("new session");
        prop_assert!(recovered.consume_provider("f","infer",&eligible).is_err());
        prop_assert_eq!(recovered.provider_receipt("f","infer").expect("receipt").expect("original").state,weaver_contracts::ProviderState::Unknown);
        prop_assert_eq!(recovered.held("f").expect("retained budget"),4);
        recovered.close().expect("recovered session drains");
        storage.close().expect("owner drains");
    }
}
