// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::fixture_nodes;
use proptest::{prop_assert_eq, proptest, test_runner::Config};
use std::{
    collections::BTreeSet,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    task::{Context, Poll, Waker},
    thread,
    time::{Duration, Instant},
};
use weaver_contracts::{DomainBinding, Task};
use weaver_ledger::{
    DeliveryCursor, Ledger,
    persistence::{self, Journal, Session},
};

proptest! {
    #![proptest_config(Config::with_cases(8))]
    #[test]
    fn queued_unaccepted_admission_preserves_old_frame_and_original_hold(
        early in proptest::bool::ANY, cancel in proptest::bool::ANY,
    ) {
        let directory=tempfile::tempdir().expect("store");
        let path=directory.path().join("selected.db");
        let storage=Session::open_with_journal(&path,Journal::Mvcc).expect("MVCC");
        let (mut own,mut plan)=fixture_nodes(&path,&["infer","second"]);
        let policy=super::POLICY.replace("context.family == \"f\"","[\"f\",\"peer\"].contains(context.family)")
            .replace("context.node == \"infer\"","[\"infer\",\"second\"].contains(context.node)");
        own.publish_typed(Some(0),&policy,super::SCHEMA,2).expect("shared source");
        plan.revision=1;plan.fence=2;
        let mut peer=plan.clone();peer.family="peer".into();
        let mut candidate=peer.clone();candidate.node="second".into();
        let record:String=persistence::one(&storage,"SELECT record FROM tasks WHERE family='f'",(),|r|r.get(0)).expect("original");
        let mut task:Task=serde_json::from_str(&record).expect("typed original");task.family="peer".into();
        for p in [&peer,&candidate] { task.stream_contracts.insert(p.node.clone(),p.digest().expect("bound original")); }
        own.register_task_domains(&task,&DomainBinding{origin:"peer-origin".into(),budget:"f".into(),history:"f".into(),budget_limit:8},None).expect("shared roots");
        own.enqueue_provider(&plan).expect("original hold");own.enqueue_provider(&peer).expect("peer hold");
        let eligible=BTreeSet::from(["primary".into()]);
        let permit=own.consume_provider("f","infer",&eligible).expect("original consume");
        own.dispatch_provider(&permit,||Ok(())).expect("original invocation");
        let release=own.prepare_provider_release(&permit,"frame","protobuf",1).expect("exact range");
        let mut delivery=None;
        own.release_provider_for_delivery(&permit,release,"protobuf",|_,d|{delivery=Some(d.split());Ok(())}).expect("known native qualification");
        let (producer,frame)=delivery.expect("frame");
        producer.acknowledge(Instant::now()+Duration::from_secs(2)).expect("ack");
        let mut cursor=DeliveryCursor::new(&plan).expect("unique owner");
        let mut holder=Ledger::open(&path).expect("peer worker");
        let peer_permit=holder.consume_provider("peer","infer",&eligible).expect("peer consume");
        let (entered,held)=mpsc::channel();let(resume,drain)=mpsc::channel();
        let (queued,waiting)=mpsc::channel();
        let aborted=Arc::new(AtomicBool::new(false));
        let accepted=thread::scope(|threads| {
            let active=threads.spawn(move || holder.dispatch_provider(&peer_permit,||{
                entered.send(()).expect("native read custody");
                drain.recv_timeout(Duration::from_secs(2)).expect("bounded release");
                Ok(())
            }));
            held.recv_timeout(Duration::from_secs(2)).expect("peer effect active");
            let cancelled=aborted.clone();let path=&path;
            let contender=threads.spawn(move || {
                let mut request=Ledger::open(path).expect("request worker");
                let announced=AtomicBool::new(false);
                let deadline=Instant::now()+Duration::from_secs(2);
                request.set_provider_range_cancellation(move || {
                    if !announced.swap(true,Ordering::Relaxed) { queued.send(()).expect("registered scheduler request"); }
                    cancelled.load(Ordering::Relaxed)||Instant::now()>=deadline
                });
                weaver_ledger::use_early_admission_barrier(early);
                let result=request.enqueue_provider(&candidate);
                weaver_ledger::use_early_admission_barrier(false);
                result
            });
            waiting.recv_timeout(Duration::from_secs(1)).expect("actual queued ticket");
            let observed=matches!(cursor.poll(&frame,&Context::from_waker(Waker::noop()),&mut Some(())),Poll::Ready(Ok(())));
            if cancel { aborted.store(true,Ordering::Relaxed); }
            resume.send(()).expect("drain peer");
            active.join().expect("peer joined").expect("peer committed");
            assert!(contender.join().expect("request joined").is_err(),"full original budget must reject or cancel");
            observed
        });
        prop_assert_eq!(accepted,!early);
        let actual=own.execution_domains("f").expect("actual original");
        prop_assert_eq!((actual.held,actual.history_count),(8,2));
        prop_assert_eq!(own.provider_receipt("peer","second").expect("no admission outcome").is_none(),true);
        prop_assert_eq!(own.consume_provider("f","infer",&eligible).is_err(),true);
    }
}
