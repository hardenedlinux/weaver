use proptest::{prop_assert, prop_assert_eq, proptest, test_runner::Config as ProptestConfig};
use std::collections::{BTreeMap, BTreeSet};
use weaver_contracts::{
    MessageRule, MessageState, StreamContract, StreamMessage, Task, WriteObservation, body_digest,
};
use weaver_ledger::{Ledger, RangePermit, StreamOwner};

pub(super) fn fixture(path: &std::path::Path) -> (Ledger, StreamContract) {
    let mut ledger = Ledger::open(path).expect("open");
    ledger
        .publish(
            None,
            include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../prod/policies/streaming/stream.cedar"
            )),
            1,
        )
        .expect("publish");
    let input = body_digest("original");
    let mut task = Task {
        provider_profile: None,
        family: "f".into(),
        principal: "alice".into(),
        profile: "p".into(),
        nodes: vec!["emit".into()],
        targets: vec!["t".into()],
        endpoints: [("t".into(), "https://provider.invalid/".into())].into(),
        body_digests: [("emit".into(), input.clone())].into(),
        stream_contracts: Default::default(),
        node_cost_bounds: [("emit".into(), 8)].into(),
        models: vec!["m".into()],
        budget: 8,
    };
    let contract = StreamContract {
        family: "f".into(),
        node: "emit".into(),
        profile: "p".into(),
        target: "t".into(),
        input_digest: input,
        destination: "tcp://127.0.0.1:9000".into(),
        messages: vec![
            MessageRule {
                id: "m0".into(),
                max_bytes: 8,
                cost_bound: 4,
            },
            MessageRule {
                id: "m1".into(),
                max_bytes: 8,
                cost_bound: 4,
            },
        ],
    };
    task.stream_contracts.insert(
        "emit".into(),
        contract.digest().expect("manifest commitment"),
    );
    ledger.register_task(&task).expect("task");
    ledger.register_stream(&contract).expect("contract");
    (ledger, contract)
}
pub(super) fn message(c: &StreamContract, id: u8, revision: u64, fence: u64) -> StreamMessage {
    StreamMessage {
        family: "f".into(),
        node: "emit".into(),
        message: format!("m{id}"),
        contract_digest: c.digest().expect("digest"),
        payload: "abcdefgh".into(),
        ceiling: 4,
        revision,
        fence,
    }
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(64))]
    #[test]
    fn arbitrary_stream_crashes_reauthorizations_and_ranges_preserve_identity(events in proptest::collection::vec((0u8..2,0u8..9,1usize..9),1..60)) {
        let temp=tempfile::tempdir().expect("temp");let path=temp.path().join("stream.db");let (mut ledger,c)=fixture(&path);
        let mut owner:Option<StreamOwner>=None;let mut pending:Option<(u8,usize,RangePermit)>=None;
        let mut registered=BTreeSet::new();let mut calls=BTreeSet::new();let mut cursors=BTreeMap::<u8,usize>::new();
        let mut revision=0;let mut fence=1;
        for (id,action,limit) in events {
            let key=format!("m{id}");
            match action {
                0=>{if ledger.enqueue_message(&message(&c,id,revision,fence)).is_ok(){registered.insert(id);cursors.entry(id).or_insert(0);}},
                1=>{if let Ok(new)=ledger.claim_stream(weaver_ledger::StreamClaim{family:"f",node:"emit",destination:&c.destination,revision,fence}){owner=Some(new);}},
                2=>{if pending.is_none() && let Some(ref o)=owner && let Ok(p)=ledger.consume_range(o,&key,limit) {pending=Some((id,limit,p));}},
                3|4=>{if let (Some((which,_,permit)),Some(o))=(pending.take(),owner.as_ref()) {
                    let offset=*cursors.get(&which).expect("original cursor");let mut completed=0;
                    let _=ledger.write_range(o,permit,|bytes|{
                        assert!(calls.insert((which,offset)),"duplicated native opportunity");
                        assert_eq!(bytes,&b"abcdefgh"[offset..offset+bytes.len()]);
                        if action==3 {completed=bytes.len();WriteObservation::Complete}else{WriteObservation::Partial(0)}
                    });
                    if completed>0 {*cursors.get_mut(&which).expect("cursor")+=completed;}
                }},
                5=>{pending=None;owner=None;drop(ledger);ledger=Ledger::open(&path).expect("restart");},
                6=>{revision=ledger.publish(Some(revision),include_str!(concat!(env!("CARGO_MANIFEST_DIR"),"/../../prod/policies/streaming/stream.cedar")),fence+1).expect("publish");fence+=1;},
                7=>{if let Some(ref o)=owner {let _=ledger.resume_message(o,&key,revision,fence);}},
                _=>{let mut forged=message(&c,id,revision,fence);forged.payload="replaced".into();if registered.contains(&id){prop_assert!(ledger.enqueue_message(&forged).is_err());}},
            }
            prop_assert_eq!(ledger.held("f").expect("held"),registered.len() as u64*4);
            prop_assert!(ledger.held("f").expect("held")<=8);
            for &key in &registered {
                let receipt=ledger.message_receipt("f","emit",&format!("m{key}")).expect("lookup").expect("receipt");
                prop_assert_eq!(receipt.cursor,*cursors.get(&key).expect("oracle cursor") as u64);
                prop_assert!(receipt.reserved>=4);
                if receipt.state==MessageState::Complete {prop_assert_eq!(receipt.cursor,8);}
            }
        }
    }
}

#[test]
fn unknown_range_after_restart_blocks_new_nonce_and_authority() {
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("stream.db");
    let (mut ledger, c) = fixture(&path);
    let original = message(&c, 0, 0, 1);
    ledger.enqueue_message(&original).expect("queue");
    let owner = ledger
        .claim_stream(weaver_ledger::StreamClaim {
            family: "f",
            node: "emit",
            destination: &c.destination,
            revision: 0,
            fence: 1,
        })
        .expect("owner");
    let permit = ledger.consume_range(&owner, "m0", 4).expect("burn");
    drop(permit);
    drop(owner);
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    ledger
        .publish(
            Some(0),
            include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../../prod/policies/streaming/stream.cedar"
            )),
            2,
        )
        .expect("new authority");
    assert!(
        ledger
            .claim_stream(weaver_ledger::StreamClaim {
                family: "f",
                node: "emit",
                destination: &c.destination,
                revision: 1,
                fence: 2
            })
            .is_err()
    );
    let mut changed = original.clone();
    changed.message = "new-nonce".into();
    changed.revision = 1;
    changed.fence = 2;
    assert!(ledger.enqueue_message(&changed).is_err());
    assert_eq!(ledger.held("f").expect("held"), 4);
}

#[test]
fn concurrent_stream_registration_and_consumption_do_not_duplicate_holds_or_writes() {
    use std::{
        sync::{
            Arc, Barrier,
            atomic::{AtomicUsize, Ordering},
        },
        thread,
    };
    let temp = tempfile::tempdir().expect("temp");
    let path = temp.path().join("stream.db");
    let (ledger, c) = fixture(&path);
    drop(ledger);
    let barrier = Arc::new(Barrier::new(8));
    let queues: Vec<_> = (0..8)
        .map(|_| {
            let path = path.clone();
            let c = c.clone();
            let barrier = barrier.clone();
            thread::spawn(move || {
                let mut ledger = Ledger::open(&path).expect("open");
                barrier.wait();
                ledger
                    .enqueue_message(&message(&c, 0, 0, 1))
                    .expect("same message")
                    .digest
            })
        })
        .collect();
    let digests: Vec<_> = queues
        .into_iter()
        .map(|w| w.join().expect("queue join"))
        .collect();
    assert!(digests.iter().all(|d| d == &digests[0]));
    let barrier = Arc::new(Barrier::new(8));
    let calls = Arc::new(AtomicUsize::new(0));
    let writers: Vec<_> = (0..8)
        .map(|_| {
            let path = path.clone();
            let c = c.clone();
            let barrier = barrier.clone();
            let calls = calls.clone();
            thread::spawn(move || {
                let mut ledger = Ledger::open(&path).expect("open");
                barrier.wait();
                if let Ok(owner) = ledger.claim_stream(weaver_ledger::StreamClaim {
                    family: "f",
                    node: "emit",
                    destination: &c.destination,
                    revision: 0,
                    fence: 1,
                }) && let Ok(permit) = ledger.consume_range(&owner, "m0", 8)
                {
                    ledger
                        .write_range(&owner, permit, |bytes| {
                            assert_eq!(bytes, b"abcdefgh");
                            calls.fetch_add(1, Ordering::SeqCst);
                            WriteObservation::Complete
                        })
                        .expect("write");
                }
            })
        })
        .collect();
    for w in writers {
        w.join().expect("writer join");
    }
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        Ledger::open(&path).expect("open").held("f").expect("held"),
        4
    );
}
