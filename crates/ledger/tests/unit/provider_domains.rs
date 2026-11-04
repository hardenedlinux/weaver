// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Real Turso transactions preserve the same actual domain image at final use.
use super::{SCHEMA, fixture_nodes};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::collections::BTreeSet;
use weaver_contracts::{DomainMigration, ProviderState, Task};
use weaver_ledger::{
    Ledger,
    persistence::{Journal, Session},
};

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn same_actual_domains_fence_original_provider_capability(
        phase in 0u8..3, restart in proptest::bool::ANY,
        revoke in proptest::bool::ANY, migrate in proptest::bool::ANY,
        revoke_first in proptest::bool::ANY
    ) {
        let directory = tempfile::tempdir().expect("directory");
        let path = directory.path().join("same-view.db");
        let storage = Session::open_with_journal(&path, Journal::Mvcc).expect("MVCC");
        let (mut ledger, plan) = fixture_nodes(&path, &["infer", "second"]);
        let record: String = weaver_ledger::persistence::one(
            &storage, "SELECT record FROM tasks WHERE family='f'", (), |row| row.get(0)
        ).expect("original task");
        let mut peer: Task = serde_json::from_str(&record).expect("original");
        peer.family = "peer".into();
        ledger.register_task(&peer).expect("independent domain");
        ledger.enqueue_provider(&plan).expect("original reservation");
        let mut sibling = plan.clone();
        sibling.node = "second".into();
        ledger.enqueue_provider(&sibling).expect("shared reservation");
        let eligible = BTreeSet::from(["primary".into()]);
        let permit = ledger.consume_provider("f", "infer", &eligible).expect("original consumption");
        let mut calls = 0;
        if phase > 0 {
            ledger.dispatch_provider(&permit, || {calls += 1; Ok(())}).expect("one original request");
        }
        let release = if phase == 1 {
            Some(ledger.prepare_provider_release(&permit, "tail", "protobuf", 1).expect("prepared row"))
        } else { None };
        let original = ledger.execution_domains("f").expect("original stamp");
        let migration = DomainMigration {
            operation_id: "same-view-union".into(), budget_from: "f".into(), budget_to: "peer".into(),
            history_from: "f".into(), history_to: "peer".into(),
            budget_from_epoch: 1, budget_to_epoch: 1, history_from_epoch: 1, history_to_epoch: 1,
        };
        if revoke && revoke_first {
            ledger.publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2)
                .expect("authoritative revocation before migration");
        }
        let receipt = if migrate {
            Some(ledger.migrate_execution_domains(&migration).expect("durable union"))
        } else { None };
        if revoke && !revoke_first {
            ledger.publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2)
                .expect("authoritative revocation");
        }
        let mut recovered = if restart { Some(Ledger::open(&path).expect("new worker")) } else { None };
        let worker = recovered.as_mut().unwrap_or(&mut ledger);
        let result = match release {
            Some(range) => worker.release_provider(&permit, range, "protobuf", |_| {calls += 1; Ok(())}),
            None if phase == 2 => worker.complete_provider(&permit, "protobuf"),
            None => worker.dispatch_provider(&permit, || {calls += 1; Ok(())}),
        };
        let stale = migrate || revoke || restart;
        prop_assert_eq!(result.is_err(), stale);
        prop_assert_eq!(calls, usize::from(phase > 0) + usize::from(!stale && phase != 2));
        if let Some(receipt) = receipt {
            prop_assert!(receipt.committed);
            prop_assert_eq!(worker.migrate_execution_domains(&migration).expect("exact lost reply recovery"), receipt);
            let mut substitution = migration.clone();
            substitution.budget_to = "f".into();
            prop_assert!(worker.migrate_execution_domains(&substitution).is_err());
        }
        if migrate {
            let mut stale = migration.clone();
            stale.operation_id = "same-parent-contender".into();
            let rejected = worker.migrate_execution_domains(&stale).expect("durable stale decision");
            prop_assert!(!rejected.committed);
            prop_assert_eq!(worker.migrate_execution_domains(&stale).expect("stale replay"), rejected);
        }
        if revoke {
            prop_assert!(matches!(
                worker.publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2),
                Err(weaver_contracts::Error::Conflict(_))
            ));
        }
        let actual = worker.execution_domains("f").expect("actual");
        prop_assert_eq!(&actual.stamp.task_key, &original.stamp.task_key);
        prop_assert_eq!(&actual.stamp.origin, &original.stamp.origin);
        prop_assert_eq!(actual.held, 8);
        prop_assert_eq!(actual.history_count, 2);
        prop_assert!(worker.consume_provider("f", "infer", &eligible).is_err());
        prop_assert_eq!(worker.enqueue_provider(&sibling).is_err(), revoke);
        prop_assert_eq!(worker.execution_domains("f").expect("idempotent reservation").held, 8);
        let state = worker.provider_receipt("f", "infer").expect("receipt").expect("original").state;
        prop_assert_eq!(state, if !stale && phase == 2 { ProviderState::Complete } else { ProviderState::Unknown });
    }
}

#[test]
fn policy_cas_waits_for_final_provider_callback() {
    use std::{sync::mpsc, thread, time::Duration};
    use weaver_contracts::Error;

    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("policy-cas.db");
    let _storage = Session::open_with_journal(&path, Journal::Mvcc).expect("MVCC");
    let (mut sender, plan) = fixture_nodes(&path, &["infer"]);
    sender.enqueue_provider(&plan).expect("reserve");
    let eligible = BTreeSet::from(["primary".into()]);
    let permit = sender
        .consume_provider("f", "infer", &eligible)
        .expect("consume");
    thread::scope(|scope| {
        let (ready, read_ready) = mpsc::channel();
        let (entered, read_entered) = mpsc::channel();
        let (result, read_result) = mpsc::channel();
        let path = &path;
        scope.spawn(move || {
            let mut source = Ledger::open(path).expect("source session");
            ready.send(()).expect("source ready");
            read_entered.recv().expect("writer entered");
            result
                .send(source.publish_typed(
                    Some(0),
                    "forbid(principal,action,resource);",
                    SCHEMA,
                    2,
                ))
                .expect("publication result");
        });
        read_ready
            .recv_timeout(Duration::from_secs(3))
            .expect("source ready");
        let sent = sender.dispatch_provider(&permit, || {
            entered.send(()).expect("actual callback entered");
            assert!(matches!(
                read_result.recv_timeout(Duration::from_millis(30)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ));
            Err::<(), _>(Error::Conflict("injected uncertain write"))
        });
        assert!(matches!(
            sent,
            Err(Error::Conflict("injected uncertain write"))
        ));
        assert_eq!(
            read_result
                .recv_timeout(Duration::from_secs(3))
                .expect("publication result")
                .expect("publication"),
            1
        );
    });
    drop(sender);
    let mut recovered = Ledger::open(&path).expect("recovered worker");
    assert!(matches!(
        recovered.publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2),
        Err(Error::Conflict(_))
    ));
    assert!(
        recovered
            .dispatch_provider::<()>(&permit, || panic!("old callback executed"))
            .is_err()
    );
    assert!(recovered.consume_provider("f", "infer", &eligible).is_err());
    let view = recovered.execution_domains("f").expect("original domains");
    assert_eq!((view.held, view.history_count), (4, 1));
    assert_eq!(
        recovered
            .provider_receipt("f", "infer")
            .expect("inspect")
            .expect("original")
            .state,
        ProviderState::Unknown
    );
}
