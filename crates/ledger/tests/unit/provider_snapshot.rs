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
use weaver_ledger::{DeliveryCursor, persistence};

proptest! {
    #![proptest_config(Config::with_cases(24))]
    #[test]
    fn one_snapshot_requalification_covers_every_exact_frame(
        widths in proptest::collection::vec(1u64..=4, 2..=4),
        mvcc in proptest::bool::ANY, revoke in proptest::bool::ANY,
        consume_first in proptest::bool::ANY,
    ) {
        let directory=tempfile::tempdir().expect("store");
        let path=directory.path().join("snapshot.db");
        let mut storage=persistence::Session::open_with_journal(&path, if mvcc { persistence::Journal::Mvcc } else { persistence::Journal::Wal }).expect("owner");
        let (mut ledger,plan)=fixture(&path);
        ledger.enqueue_provider(&plan).expect("reserve");
        let permit=ledger.consume_provider("f","infer",&BTreeSet::from(["primary".into()])).expect("consume");
        ledger.dispatch_provider(&permit,||Ok(())).expect("dispatch");
        let specs:Vec<_>=widths.iter().map(|width|("exact",*width)).collect();
        let releases=ledger.prepare_provider_releases(&permit,&specs,"arrow").expect("prepare");
        let mut staged=None;
        let before=ledger.transaction_timings().commit.attempts;
        let mut cursor=DeliveryCursor::new(&plan).expect("cursor");
        let cx=Context::from_waker(Waker::noop());
        let (_,tail)=ledger.release_provider_group_for_delivery(&permit,releases,"arrow",|_,delivery|{
            let (producer,frame)=delivery.split();
            assert!(producer.acknowledge(Instant::now()+Duration::from_secs(1)).is_err(),"native outcome was not confirmed");
            assert!(cursor.poll(&frame,&cx,&mut Some(())).is_pending());
            staged=Some((producer,frame)); Ok(())
        }).expect("atomic group commit");
        prop_assert_eq!(ledger.transaction_timings().commit.attempts-before,1);
        let mut frames=vec![staged.expect("first")];
        frames.extend(tail.into_iter().map(|delivery|delivery.split()));
        for (producer,_) in &frames { producer.acknowledge(Instant::now()+Duration::from_secs(1)).expect("acknowledge own frame"); }
        let start=usize::from(consume_first);
        if consume_first { prop_assert!(matches!(cursor.poll(&frames[0].1,&cx,&mut Some(())),Poll::Ready(Ok(())))); }
        let tx=persistence::begin(&mut storage).expect("semantic ticket");
        persistence::exec(&tx,"UPDATE tasks SET held=held WHERE family='f'",()).expect("current view write");
        tx.commit().expect("changed cut");
        if revoke { ledger.publish_typed(Some(0),"forbid(principal,action,resource);",SCHEMA,2).expect("revoke"); }
        prop_assert!(cursor.poll(&frames[start].1,&cx,&mut Some(())).is_pending());
        let before=ledger.transaction_timings().commit.attempts;
        let refresh=ledger.refresh_provider_delivery(&permit,&frames[start].0,"arrow");
        prop_assert_eq!(refresh.is_ok(),!revoke);
        if !revoke {
            prop_assert_eq!(ledger.transaction_timings().commit.attempts-before,1);
            let commits=ledger.transaction_timings().commit.attempts;
            for (_,frame) in frames.iter().skip(start) {
                prop_assert!(matches!(cursor.poll(frame,&cx,&mut Some(())),Poll::Ready(Ok(()))),"shared qualification not published atomically");
                prop_assert!(matches!(cursor.poll(frame,&cx,&mut Some(())),Poll::Ready(Err(_))),"duplicated interval");
            }
            prop_assert_eq!(ledger.transaction_timings().commit.attempts,commits,"a handoff opened a native transaction");
        }
        let original=ledger.provider_receipt("f","infer").expect("inspect").expect("original");
        prop_assert_eq!((original.events,original.held),(widths.iter().sum::<u64>(),4));
        prop_assert_eq!(original.state,weaver_contracts::ProviderState::Unknown);
    }
}

#[test]
fn late_manifest_mismatch_rolls_back_every_earlier_burn() {
    let directory = tempfile::tempdir().expect("store");
    let path = directory.path().join("partial.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("reserve");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("dispatch");
    let releases = ledger
        .prepare_provider_releases(&permit, &[("first", 1), ("second", 1)], "protobuf")
        .expect("prepare");
    let mut storage = persistence::Session::open(&path).expect("fault connection");
    let tx = persistence::begin(&mut storage).expect("fault ticket");
    persistence::exec(
        &tx,
        "UPDATE provider_releases SET digest='changed' WHERE sequence=1",
        (),
    )
    .expect("mismatch");
    tx.commit().expect("fault commit");
    let mut staged = false;
    assert!(
        ledger
            .release_provider_group_for_delivery(&permit, releases, "protobuf", |_, _| {
                staged = true;
                Ok(())
            })
            .is_err()
    );
    assert!(!staged, "partial manifest published");
    let released: u64 = persistence::one(
        &storage,
        "SELECT COUNT(*) FROM provider_releases WHERE state='released'",
        (),
        |row| row.get(0),
    )
    .expect("native state");
    assert_eq!(released, 0, "earlier CAS escaped rollback");
    assert_eq!(
        ledger
            .provider_receipt("f", "infer")
            .expect("inspect")
            .expect("original")
            .held,
        4
    );
}

#[test]
fn post_staging_native_failure_cannot_publish_a_partial_snapshot() {
    for journal in [persistence::Journal::Wal, persistence::Journal::Mvcc] {
        let directory = tempfile::tempdir().expect("store");
        let path = directory.path().join("post-stage.db");
        let storage = persistence::Session::open_with_journal(&path, journal).expect("owner");
        let (mut ledger, plan) = fixture(&path);
        ledger.enqueue_provider(&plan).expect("reserve");
        let permit = ledger
            .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
            .expect("consume");
        ledger
            .dispatch_provider(&permit, || Ok(()))
            .expect("dispatch");
        let releases = ledger
            .prepare_provider_releases(&permit, &[("first", 1), ("second", 1)], "protobuf")
            .expect("prepare");
        persistence::script(&storage,"CREATE TRIGGER fail_second_snapshot_row BEFORE UPDATE ON provider_releases WHEN NEW.sequence=1 AND NEW.state='released' BEGIN SELECT RAISE(ABORT,'second CAS failed'); END;").expect("native post-staging fault");
        let mut inert = None;
        assert!(
            ledger
                .release_provider_group_for_delivery(
                    &permit,
                    releases,
                    "protobuf",
                    |_, delivery| {
                        inert = Some(delivery.split());
                        Ok(())
                    }
                )
                .is_err()
        );
        let (producer, frame) = inert.expect("first frame really staged");
        assert!(
            producer
                .acknowledge(Instant::now() + Duration::from_secs(1))
                .is_err()
        );
        let mut cursor = DeliveryCursor::new(&plan).expect("cursor");
        let cx = Context::from_waker(Waker::noop());
        assert!(matches!(
            cursor.poll(&frame, &cx, &mut Some(())),
            Poll::Ready(Err(_))
        ));
        let released: u64 = persistence::one(
            &storage,
            "SELECT COUNT(*) FROM provider_releases WHERE state='released'",
            (),
            |row| row.get(0),
        )
        .expect("native outcome");
        assert_eq!(released, 0, "earlier group row escaped native rollback");
        assert_eq!(
            ledger
                .provider_receipt("f", "infer")
                .expect("inspect")
                .expect("original")
                .held,
            4
        );
    }
}

#[test]
fn a_request_arriving_during_qualification_cannot_trigger_a_second_native_read() {
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    };
    use weaver_ledger::{
        DeliveryFrame,
        persistence::commit_observer::{Cut, Decision, Observer},
    };
    struct Rerequest {
        cursor: Mutex<DeliveryCursor>,
        frame: Arc<DeliveryFrame>,
        seen: AtomicBool,
    }
    impl Observer for Rerequest {
        fn observe(&self, cut: Cut) -> Decision {
            if cut == Cut::BeforeSnapshotPublication {
                let cx = Context::from_waker(Waker::noop());
                assert!(
                    self.cursor
                        .lock()
                        .expect("cursor")
                        .poll(&self.frame, &cx, &mut Some(()))
                        .is_pending()
                );
                self.seen.store(true, Ordering::Release);
            }
            Decision::Continue
        }
    }
    let directory = tempfile::tempdir().expect("store");
    let path = directory.path().join("refresh-race.db");
    let (mut ledger, plan) = fixture(&path);
    ledger.enqueue_provider(&plan).expect("reserve");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    ledger
        .dispatch_provider(&permit, || Ok(()))
        .expect("dispatch");
    let release = ledger
        .prepare_provider_release(&permit, "frame", "protobuf", 1)
        .expect("prepare");
    let mut first = None;
    ledger
        .release_provider_for_delivery(&permit, release, "protobuf", |_, delivery| {
            first = Some(delivery.split());
            Ok(())
        })
        .expect("initial commit");
    let (producer, frame) = first.expect("frame");
    producer
        .acknowledge(Instant::now() + Duration::from_secs(1))
        .expect("ack");
    let mut storage = persistence::Session::open(&path).expect("source");
    let tx = persistence::begin(&mut storage).expect("new cut");
    persistence::exec(&tx, "UPDATE tasks SET held=held WHERE family='f'", ())
        .expect("no-op source update");
    tx.commit().expect("source outcome");
    let observer = Arc::new(Rerequest {
        cursor: Mutex::new(DeliveryCursor::new(&plan).expect("cursor")),
        frame: Arc::new(frame),
        seen: AtomicBool::new(false),
    });
    let cx = Context::from_waker(Waker::noop());
    assert!(
        observer
            .cursor
            .lock()
            .expect("cursor")
            .poll(&observer.frame, &cx, &mut Some(()))
            .is_pending()
    );
    let pending = persistence::begin(&mut storage).expect("later semantic barrier");
    let reads = ledger.transaction_timings().commit.attempts;
    assert_eq!(
        producer
            .progress()
            .expect("defer already pending authority"),
        None,
        "an already visible semantic barrier must defer the native read"
    );
    assert_eq!(ledger.transaction_timings().commit.attempts, reads);
    pending.commit().expect("later semantic outcome");
    assert!(
        observer
            .cursor
            .lock()
            .expect("cursor")
            .poll(&observer.frame, &cx, &mut Some(()))
            .is_pending()
    );
    assert_eq!(
        producer.progress().expect("request"),
        Some(weaver_ledger::DeliveryWait::Refresh)
    );
    ledger.observe_provider_commit(observer.clone());
    let commits = ledger.transaction_timings().commit.attempts;
    ledger
        .refresh_provider_delivery(&permit, &producer, "protobuf")
        .expect("native read and publication");
    assert!(
        observer.seen.load(Ordering::Acquire),
        "real deciding cut was not reached"
    );
    assert_eq!(ledger.transaction_timings().commit.attempts, commits + 1);
    assert_eq!(
        producer
            .progress()
            .expect("late request joined current cut"),
        None
    );
    assert!(matches!(
        observer
            .cursor
            .lock()
            .expect("cursor")
            .poll(&observer.frame, &cx, &mut Some(())),
        Poll::Ready(Ok(()))
    ));
}
