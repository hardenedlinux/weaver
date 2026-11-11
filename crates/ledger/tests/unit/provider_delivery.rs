// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{SCHEMA, fixture};
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::{
    collections::BTreeSet,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll, Wake, Waker},
    time::{Duration, Instant},
};
use weaver_ledger::{DeliveryCursor, DeliveryWait, Ledger, persistence};

#[derive(Default)]
struct DeliveryWake(AtomicBool);

impl Wake for DeliveryWake {
    fn wake(self: Arc<Self>) {
        self.0.store(true, Ordering::Relaxed);
    }
}

#[test]
fn expired_delivery_keeps_the_payload_inert() {
    let directory = tempfile::tempdir().expect("store");
    let path = directory.path().join("expired.db");
    let _custody = persistence::Session::open_with_journal(&path, persistence::Journal::Wal)
        .expect("native owner");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("reserve");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("dispatch burn");
    let release = ledger
        .prepare_provider_release(&permit, "expired-frame", "arrow", 1)
        .expect("range");
    let mut staged = None;
    ledger
        .release_provider_for_delivery(&permit, release, "arrow", |_, delivery| {
            staged = Some(delivery.split());
            Ok(())
        })
        .expect("native release committed");
    let (producer, frame) = staged.expect("inert frame");
    producer
        .acknowledge(Instant::now() - Duration::from_secs(1))
        .expect("acknowledged expired grant");
    let mut cursor = DeliveryCursor::new(&plan).expect("receiver");
    let cx = Context::from_waker(Waker::noop());
    let mut payload = Some(42);
    assert!(matches!(
        cursor.poll(&frame, &cx, &mut payload),
        Poll::Ready(Err(weaver_contracts::Error::Conflict(
            "delivery grant expired"
        )))
    ));
    assert_eq!(payload, Some(42));
    drop((producer, frame, cursor));
    ledger.close().expect("release worker");
}

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
        let signal = Arc::new(DeliveryWake::default());
        let waker = Waker::from(signal.clone());
        let producer_cx = Context::from_waker(&waker);
        prop_assert!(producer.poll_progress_ready(&producer_cx).is_pending());
        // A real different connection commits after validation and before the final owner turn.
        let tx = persistence::begin(&mut storage).expect("close real write");
        prop_assert!(cursor.poll(&frame, &cx, &mut Some(())).is_pending(), "closed lane admitted bytes");
        persistence::exec(&tx,"UPDATE tasks SET held=held WHERE family='f'",()).expect("same-view native write");
        tx.commit().expect("native commit");
        prop_assert!(cursor.poll(&frame, &cx, &mut Some(())).is_pending(), "old view skipped requalification");
        prop_assert!(signal.0.swap(false, Ordering::Relaxed), "refresh did not wake the producer");
        prop_assert_eq!(producer.wait(|| false, Instant::now()+Duration::from_secs(1)).expect("refresh"), DeliveryWait::Refresh);
        if revoke { ledger.publish_typed(Some(0), "forbid(principal,action,resource);", SCHEMA, 2).expect("revoke"); }
        let refreshed = ledger.refresh_provider_delivery(&permit, &producer, "arrow");
        prop_assert_eq!(refreshed.is_ok(), !revoke);
        if !revoke {
            prop_assert!(producer.poll_progress_ready(&producer_cx).is_pending());
            prop_assert!(matches!(cursor.poll(&frame, &cx, &mut Some(())), Poll::Ready(Ok(()))));
            prop_assert!(signal.0.load(Ordering::Relaxed), "acceptance did not wake the producer");
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

proptest! {
    #![proptest_config(Config::with_cases(24))]
    #[test]
    fn exact_range_progress_preserves_queued_authorization(
        widths in proptest::collection::vec(1u64..=4, 2..=4),
        mvcc in proptest::bool::ANY, conservative in proptest::bool::ANY,
    ) {
        weaver_ledger::use_conservative_range_invalidation(conservative);
        let directory = tempfile::tempdir().expect("store");
        let path = directory.path().join("progress.db");
        let _custody = persistence::Session::open_with_journal(&path,
            if mvcc { persistence::Journal::Mvcc } else { persistence::Journal::Wal }).expect("owner");
        let (mut ledger, plan) = fixture(&path);
        ledger.enqueue_provider(&plan).expect("reserve");
        let permit = ledger.consume_provider("f", "infer", &BTreeSet::from(["primary".into()])).expect("consume");
        ledger.dispatch_provider(&permit, || Ok(())).expect("dispatch burn");
        let ranges: Vec<_> = widths.iter().map(|width| ("exact-frame", *width)).collect();
        let releases = ledger.prepare_provider_releases(&permit, &ranges, "arrow").expect("ranges");
        let mut frames = Vec::new();
        for release in releases {
            ledger.release_provider_for_delivery(&permit, release, "arrow", |_, delivery| {
                frames.push(delivery.split()); Ok(())
            }).expect("durable exact release");
            frames.last().expect("frame").0.acknowledge(Instant::now()+Duration::from_secs(1)).expect("acknowledge");
        }
        // A fresh append must not invalidate any already released queued span.
        ledger.prepare_provider_release(&permit, "next-frame", "arrow", 1).expect("fresh append");
        let mut cursor = DeliveryCursor::new(&plan).expect("receiver");
        let cx = Context::from_waker(Waker::noop());
        for (producer, frame) in &frames {
            if conservative {
                prop_assert!(cursor.poll(frame, &cx, &mut Some(())).is_pending());
                ledger.refresh_provider_delivery(&permit, producer, "arrow").expect("old conservative requalification");
            }
            prop_assert!(matches!(cursor.poll(frame, &cx, &mut Some(())), Poll::Ready(Ok(()))),
                "progress alone invalidated an exact earlier frame");
            prop_assert!(matches!(cursor.poll(frame, &cx, &mut Some(())), Poll::Ready(Err(_))), "cursor reused");
        }
        let receipt = ledger.provider_receipt("f", "infer").expect("inspect").expect("original");
        prop_assert_eq!((receipt.held, receipt.state), (4, weaver_contracts::ProviderState::Unknown));
        weaver_ledger::use_conservative_range_invalidation(false);
    }
}

#[test]
fn pending_range_release_cannot_block_an_already_acknowledged_frame() {
    let directory = tempfile::tempdir().expect("store");
    let path = directory.path().join("pending-progress.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("reserve");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("dispatch burn");
    let mut releases = ledger
        .prepare_provider_releases(&permit, &[("first", 1), ("second", 1)], "protobuf")
        .expect("prepare")
        .into_iter();
    let mut first = None;
    ledger
        .release_provider_for_delivery(
            &permit,
            releases.next().expect("first"),
            "protobuf",
            |_, d| {
                first = Some(d.split());
                Ok(())
            },
        )
        .expect("first commit");
    let (producer, frame) = first.expect("frame");
    producer
        .acknowledge(Instant::now() + Duration::from_secs(1))
        .expect("ack");
    let mut cursor = DeliveryCursor::new(&plan).expect("receiver");
    let cx = Context::from_waker(Waker::noop());
    ledger
        .release_provider_for_delivery(
            &permit,
            releases.next().expect("second"),
            "protobuf",
            |_, d| {
                assert!(
                    matches!(cursor.poll(&frame, &cx, &mut Some(())), Poll::Ready(Ok(()))),
                    "unrelated progress ticket blocked an acknowledged frame"
                );
                let (_uncommitted_producer, uncommitted) = d.split();
                assert!(
                    cursor.poll(&uncommitted, &cx, &mut Some(())).is_pending(),
                    "progress lane activated its own uncommitted frame"
                );
                Ok(())
            },
        )
        .expect("second commit");
}
