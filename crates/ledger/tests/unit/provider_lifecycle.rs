// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::fixture_nodes;
use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config};
use std::{
    collections::BTreeSet,
    sync::{Arc, Mutex},
    task::{Context, Poll, Waker},
    time::{Duration, Instant},
};
use weaver_contracts::{DomainBinding, Task};
use weaver_ledger::{
    DeliveryCursor, DeliveryFrame,
    persistence::{
        self, Journal, Session,
        commit_observer::{Cut, Decision, Observer},
    },
};

struct Probe {
    cursor: Mutex<DeliveryCursor>,
    frames: [DeliveryFrame; 3],
    seen: Mutex<[Option<bool>; 3]>,
}
impl Probe {
    fn during_request(&self) {
        let mut seen = self.seen.lock().expect("request observation");
        let at = if seen[0] == Some(true) && seen[1] == Some(true) {
            2
        } else {
            0
        };
        let cx = Context::from_waker(Waker::noop());
        seen[2] = Some(matches!(
            self.cursor
                .lock()
                .expect("cursor")
                .poll(&self.frames[at], &cx, &mut Some(())),
            Poll::Ready(Ok(()))
        ));
    }
}
impl Observer for Probe {
    fn observe(&self, cut: Cut) -> Decision {
        let at = match cut {
            Cut::BeforeLifecycleCommit | Cut::BeforeAdmissionCommit => 0,
            Cut::AfterLifecycleCommit | Cut::AfterAdmissionCommit => 1,
            _ => return Decision::Continue,
        };
        let mut seen = self.seen.lock().expect("observations");
        if seen[at].is_none() {
            let cx = Context::from_waker(Waker::noop());
            // If the earlier frame was fenced, preserve its cursor for the
            // after-commit check instead of advancing to an unoffered interval.
            let frame = if at == 1 && seen[0] == Some(true) {
                1
            } else {
                0
            };
            seen[at] = Some(matches!(
                self.cursor
                    .lock()
                    .expect("cursor")
                    .poll(&self.frames[frame], &cx, &mut Some(())),
                Poll::Ready(Ok(()))
            ));
        }
        Decision::Continue
    }
}

proptest! {
    #![proptest_config(Config::with_cases(32))]
    #[test]
    fn peer_lifecycle_preserves_complete_view_but_shared_admission_does_not(
        phase in 0u8..4, same_origin in proptest::bool::ANY,
        mvcc in proptest::bool::ANY, conservative in proptest::bool::ANY,
    ) {
        let directory=tempfile::tempdir().expect("store");let path=directory.path().join("local.db");
        let storage=Session::open_with_journal(&path,if mvcc {Journal::Mvcc}else{Journal::Wal}).expect("journal");
        let (mut ledger,mut plan)=fixture_nodes(&path,&["infer","second"]);
        let policy=super::POLICY.replace("context.family == \"f\"", "[\"f\",\"peer\"].contains(context.family)").replace("context.node == \"infer\"", "[\"infer\",\"second\"].contains(context.node)");
        ledger.publish_typed(Some(0),&policy,super::SCHEMA,2).expect("explicit peer Policy");
        plan.revision=1;plan.fence=2;
        let mut peer=plan.clone();

        if same_origin {peer.node="second".into();} else {
            peer.family="peer".into();
            let record:String=persistence::one(&storage,"SELECT record FROM tasks WHERE family='f'",(),|r|r.get(0)).expect("original task");
            let mut task:Task=serde_json::from_str(&record).expect("typed task");task.family=peer.family.clone();
            task.stream_contracts.insert(peer.node.clone(),peer.digest().expect("bound peer"));
            ledger.register_task_domains(&task,&DomainBinding{origin:"peer-origin".into(),budget:"f".into(),history:"f".into(),budget_limit:8},None).expect("shared original domains");
        }
        ledger.enqueue_provider(&plan).expect("original hold");if phase!=3 {ledger.enqueue_provider(&peer).expect("peer hold");}
        let eligible=BTreeSet::from(["primary".into()]);
        let own=ledger.consume_provider("f","infer",&eligible).expect("own consume");
        ledger.dispatch_provider(&own,||Ok(())).expect("own dispatch");
        let peer_permit=if phase>0 && phase<3 {Some(ledger.consume_provider(&peer.family,&peer.node,&eligible).expect("peer consume"))} else {None};
        if phase==2 { ledger.dispatch_provider(peer_permit.as_ref().expect("permit"),||Ok(())).expect("peer dispatch"); }
        let releases=ledger.prepare_provider_releases(&own,&[("first",1),("second",1),("third",1)],"protobuf").expect("manifest");
        let mut staged=None;
        let (_,tail)=ledger.release_provider_group_for_delivery(&own,releases,"protobuf",|_,d|{staged=Some(d.split());Ok(())}).expect("snapshot");
        let (first,frame0)=staged.expect("first");let mut tail=tail.into_iter();let(second,frame1)=tail.next().expect("second").split();let(third,frame2)=tail.next().expect("third").split();
        first.acknowledge(Instant::now()+Duration::from_secs(1)).expect("first ack");
        second.acknowledge(Instant::now()+Duration::from_secs(1)).expect("second ack");third.acknowledge(Instant::now()+Duration::from_secs(1)).expect("third ack");
        let probe=Arc::new(Probe{cursor:Mutex::new(DeliveryCursor::new(&plan).expect("cursor")),frames:[frame0,frame1,frame2],seen:Mutex::new([None,None,None])});
        ledger.observe_provider_commit(probe.clone());
        weaver_ledger::use_full_lifecycle_invalidation(conservative);
        match phase {
            0 => {ledger.consume_provider(&peer.family,&peer.node,&eligible).expect("observed consumption");}
            1 => {ledger.dispatch_provider(peer_permit.as_ref().expect("permit"),||{probe.during_request();Ok(())}).expect("observed dispatch");}
            2 => {ledger.complete_provider_with_usage(peer_permit.as_ref().expect("permit"),"protobuf",Some([1,1,0,0])).expect("observed terminal");}
            _ => {ledger.enqueue_provider(&peer).expect("observed shared admission");}
        }
        weaver_ledger::use_full_lifecycle_invalidation(false);
        let accepted=phase!=3 && mvcc && !same_origin && !conservative;
        prop_assert_eq!(*probe.seen.lock().expect("checked actual native cuts"),[Some(accepted),Some(accepted),if phase==1 {Some(accepted)}else{None}]);
        let current=ledger.execution_domains("f").expect("current view");prop_assert_eq!((current.held,current.history_count),(8,2));
        prop_assert_eq!(ledger.provider_receipt("f","infer").expect("receipt").expect("original").held,if same_origin {8}else{4});
        prop_assert!(ledger.consume_provider("f","infer",&eligible).is_err(),"original claim reopened");
    }
}
