// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{SCHEMA, fixture};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::{
    collections::BTreeSet,
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};
use weaver_ledger::{DeliveryCursor, DeliveryWait, Ledger, persistence};

proptest! {
    #![proptest_config(Config::with_cases(24))]
    #[test]
    fn staged_receipt_rejoins_actual_turso_view_and_is_consumed_once(
        rows in 1u64..=4, revoke in proptest::bool::ANY, mvcc in proptest::bool::ANY,
    ) {
        let directory = tempfile::tempdir().expect("store");
        let path = directory.path().join("delivery.db");
        let mut storage = persistence::Session::open_with_journal(&path,
            if mvcc { persistence::Journal::Mvcc } else { persistence::Journal::Wal }).expect("owner");
        let (mut ledger, plan) = fixture(&path);
        ledger.enqueue_provider(&plan).expect("reserve");
        let permit = ledger.consume_provider("f", "infer", &BTreeSet::from(["primary".into()])).expect("consume");
        ledger.dispatch_provider(&permit, || Ok(())).expect("dispatch burn");
        let release = ledger.prepare_provider_release(&permit, "exact-frame", "arrow", rows).expect("range");
        let mut cursor = DeliveryCursor::new(&plan).expect("receiver");
        let cx = Context::from_waker(Waker::noop());
        let mut staged = None;
        ledger.release_provider_for_delivery(&permit, release, "arrow", |_, delivery| {
            let (producer, frame) = delivery.split();
            assert!(cursor.poll(&frame, &cx, &mut Some(())).is_pending(), "SQL callback cannot deliver");
            staged = Some((producer, frame));
            Ok(())
        }).expect("native release committed");
        let (producer, frame) = staged.expect("inert frame");
        prop_assert!(cursor.poll(&frame, &cx, &mut Some(())).is_pending(), "commit is not producer acknowledgment");
        producer.acknowledge(Instant::now()+Duration::from_secs(1)).expect("confirmed receipt");
        // A real different connection commits after validation and before the final owner turn.
        let tx = persistence::begin(&mut storage).expect("close real write");
        prop_assert!(cursor.poll(&frame, &cx, &mut Some(())).is_pending(), "closed lane admitted bytes");
        persistence::exec(&tx,"UPDATE tasks SET held=held WHERE family='f'",()).expect("same-view native write");
        tx.commit().expect("native commit");
        prop_assert!(cursor.poll(&frame, &cx, &mut Some(())).is_pending(), "old view skipped requalification");
        prop_assert_eq!(producer.wait(|| false, Instant::now()+Duration::from_secs(1)).expect("refresh"), DeliveryWait::Refresh);
        if revoke { ledger.publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2).expect("revoke"); }
        let refreshed = ledger.refresh_provider_delivery(&permit, &producer, "arrow");
        prop_assert_eq!(refreshed.is_ok(), !revoke);
        if !revoke {
            prop_assert!(matches!(cursor.poll(&frame, &cx, &mut Some(())), Poll::Ready(Ok(()))));
            prop_assert!(matches!(cursor.poll(&frame, &cx, &mut Some(())), Poll::Ready(Err(_))), "range duplicated");
        }
        drop(producer); drop(frame); drop(cursor); drop(storage);
        ledger.close().expect("release worker");
        let _recovery_custody = persistence::Session::open_with_journal(&path,
            if mvcc { persistence::Journal::Mvcc } else { persistence::Journal::Wal }).expect("explicit recovery profile");
        let mut recovered = Ledger::open(&path).expect("recovery");
        prop_assert!(recovered.consume_provider("f","infer", &BTreeSet::from(["primary".into()])).is_err());
        let original = recovered.provider_receipt("f","infer").expect("inspect").expect("original");
        prop_assert_eq!((original.events, original.held), (rows, 4));
        prop_assert_eq!(original.state, weaver_contracts::ProviderState::Unknown);
    }
}
