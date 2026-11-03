// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use super::stream_properties::{fixture, message};
use proptest::{collection, prop_assert_eq, proptest, test_runner::Config};
use std::collections::{BTreeMap, BTreeSet};
use weaver_contracts::{Publication, PublicationOutcome};
use weaver_ledger::{Ledger, StreamClaim};

fn change(id: u8) -> Publication {
    Publication {
        operation_id: format!("policy-{id}"),
        expected_revision: Some(0),
        fence: 2,
        policy: include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../prod/policies/streaming/stream.cedar"
        ))
        .into(),
        schema: include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../prod/policies/streaming/schema.json"
        ))
        .into(),
    }
}

#[derive(Clone, Copy, Debug)]
enum Command {
    Stage(u8),
    Decide(u8),
    Restart,
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn pending_policy_prefixes_preserve_barriers_and_holds(
        suffix in collection::vec((0u8..3, 0u8..2), 1..32)) {
        let temp=tempfile::tempdir().expect("store"); let path=temp.path().join("barrier.db");
        let (mut ledger, contract)=fixture(&path);
        ledger.enqueue_message(&message(&contract,0,0,1)).expect("original claim");
        let mut pending=BTreeSet::new(); let mut decided=BTreeMap::new();
        let mut revision=0; let mut fence=1;
        // A real legal pending path survives shrinking; no all-observation trace.
        let commands=std::iter::once(Command::Stage(0)).chain(suffix.into_iter().map(|(action,id)| match action {
            0=>Command::Stage(id), 1=>Command::Decide(id), _=>Command::Restart,
        }));
        for command in commands {
            match command {
                Command::Stage(id)=>{
                    if !decided.contains_key(&id) {pending.insert(id);}
                    let key=ledger.stage_authority(&change(id)).expect("durable stage");
                    prop_assert_eq!(key.digest,change(id).digest().expect("identity"));
                },
                Command::Decide(id)=>{
                    let expected=*decided.entry(id).or_insert_with(|| {
                        if revision==0 {revision=1;fence=2;PublicationOutcome::Committed}
                        else {PublicationOutcome::Rejected}
                    });
                    pending.remove(&id);
                    prop_assert_eq!(ledger.publish_authority(&change(id)).expect("decision").outcome,expected);
                },
                Command::Restart=>{drop(ledger);ledger=Ledger::open(&path).expect("restart");},
            }
            let result=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&contract.destination,revision,fence});
            prop_assert_eq!(result.is_ok(),pending.is_empty(),"current guard differs from independent pending model");
            prop_assert_eq!(ledger.held("f").expect("hold"),4);
        }
    }
}

#[test]
fn staged_policy_blocks_an_already_consumed_range_without_refunding() {
    let temp = tempfile::tempdir().expect("store");
    let path = temp.path().join("range.db");
    let (mut ledger, c) = fixture(&path);
    ledger
        .enqueue_message(&message(&c, 0, 0, 1))
        .expect("queue");
    let owner = ledger
        .claim_stream(StreamClaim {
            family: "f",
            node: "emit",
            destination: &c.destination,
            revision: 0,
            fence: 1,
        })
        .expect("owner");
    let permit = ledger.consume_range(&owner, "m0", 4).expect("burn");
    ledger.stage_authority(&change(0)).expect("stage");
    let mut calls = 0;
    assert!(
        ledger
            .write_range(&owner, permit, |_| {
                calls += 1;
                weaver_contracts::WriteObservation::Complete
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    assert_eq!(ledger.held("f").expect("hold"), 4);
    let mut forged = change(0);
    forged.fence = 3;
    assert!(ledger.stage_authority(&forged).is_err());
    assert!(ledger.publish_authority(&forged).is_err());
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(
        ledger
            .publication_receipt(&weaver_contracts::PublicationKey {
                operation_id: change(0).operation_id,
                digest: change(0).digest().expect("digest")
            })
            .expect("inspect")
            .is_none()
    );
    ledger.publish_authority(&change(0)).expect("same outcome");
    assert_eq!(ledger.held("f").expect("hold"), 4);
}
