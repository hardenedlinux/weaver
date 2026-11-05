// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{POLICY, SCHEMA, fixture, fixture_nodes, fixture_with_ceiling};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::{cell::Cell, collections::BTreeSet};
use weaver_ledger::{Ledger, ProviderDispatch, ProviderRelease};

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
