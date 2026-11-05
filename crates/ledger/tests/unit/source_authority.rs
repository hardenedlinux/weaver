// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use proptest::{collection, prop_assert_eq, proptest, test_runner::Config};
use std::collections::{BTreeMap, BTreeSet};
use weaver_contracts::{
    Publication, PublicationOutcome, SourceIdentity, SourceRotation, SourceRotationOutcome,
    body_digest,
};
use weaver_ledger::{Ledger, StreamClaim};

pub fn identity(id: u8) -> SourceIdentity {
    SourceIdentity {
        certificate_sha256: body_digest(&format!("certificate-{id}")),
        public_key_sha256: body_digest(&format!("SPKI-{id}")),
        credential_sha256: body_digest("shared role credential"),
    }
}
pub fn rotation(id: u8) -> SourceRotation {
    SourceRotation {
        operation_id: format!("handoff-{id}"),
        expected_epoch: u64::from(id),
        next: identity((id + 1) % 3),
    }
}
fn change() -> Publication {
    Publication {
        operation_id: "guarded".into(),
        expected_revision: Some(0),
        fence: 1,
        policy: include_str!("../../../../prod/policies/streaming/stream.cedar").into(),
        schema: include_str!("../../../../prod/policies/streaming/schema.json").into(),
    }
}

#[test]
fn scope_precheck_cannot_authorize_after_another_connection_rotates() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("cut.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("bootstrap");
    let mut other = Ledger::open(&path).expect("other");
    let result = ledger.with_authenticated_source(&identity(0), |l| {
        other.rotate_source_authority(&identity(0), &rotation(0))?;
        l.stage_authority(&Publication {
            expected_revision: None,
            ..change()
        })
    });
    assert!(result.is_err());
    assert!(
        ledger
            .with_authenticated_source(&identity(0), |_| Ok(()))
            .is_err()
    );
    assert_eq!(
        ledger
            .source_authority()
            .expect("view")
            .expect("current")
            .epoch,
        1
    );
    // The exact original result remains queryable by its retired proposer.
    let original = ledger
        .rotate_source_authority(&identity(0), &rotation(0))
        .expect("lost reply replay");
    assert_eq!(original.outcome, SourceRotationOutcome::Committed);
    assert!(
        ledger
            .with_authenticated_source(&identity(0), |l| l.publish_authority(&Publication {
                expected_revision: None,
                ..change()
            }))
            .is_err()
    );
}

#[test]
fn populated_unenrolled_store_cannot_be_claimed_by_new_startup_credentials() {
    let temp = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(temp.path().join("old.db")).expect("store");
    ledger
        .publish_typed(None, &change().policy, &change().schema, 1)
        .expect("old authority");
    assert!(
        ledger
            .with_authenticated_source(&identity(0), |_| Ok(()))
            .is_err()
    );
    assert!(ledger.source_authority().expect("unclaimed").is_none());
}

#[test]
fn a_reissued_certificate_cannot_resurrect_a_retired_public_key() {
    let temp = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(temp.path().join("keys.db")).expect("store");
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("initial");
    ledger
        .rotate_source_authority(&identity(0), &rotation(0))
        .expect("first");
    let mut reissue = rotation(1);
    reissue.next = identity(0);
    reissue.next.certificate_sha256 = body_digest("new certificate same SPKI");
    let rejected = ledger
        .rotate_source_authority(&identity(1), &reissue)
        .expect("durable refusal");
    assert_eq!(rejected.outcome, SourceRotationOutcome::Rejected);
    assert_eq!(rejected.authority.epoch, 1);
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn source_handoffs_and_old_workers_preserve_original_unknown_budget(actions in collection::vec((0u8..4,0u8..3,0u8..3),1..36)) {
        let temp=tempfile::tempdir().expect("directory");let path=temp.path().join("model.db");
        let mut ledger=Ledger::open(&path).expect("store");ledger.with_authenticated_source(&identity(0),|_|Ok(())).expect("initial key");drop(ledger);
        let (mut ledger,c)=super::stream_properties::fixture(&path);ledger.enqueue_message(&super::stream_properties::message(&c,0,0,1)).expect("claim");
        let owner=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&c.destination,revision:0,fence:1}).expect("owner");
        let permit=ledger.consume_range(&owner,"m0",8).expect("burn");ledger.write_range(&owner,permit,|_|weaver_contracts::WriteObservation::Partial(2)).expect("partial");
        let mut current=0u8;let mut epoch=0u64;let mut used=BTreeSet::from([0u8]);let mut records:BTreeMap<u8,(u8,weaver_contracts::SourceRotationReceipt)>=BTreeMap::new();let mut publication:Option<weaver_contracts::PublicationReceipt>=None;
        for (action,actor,id) in actions {
            match action {
                0=>{
                    let expected=if let Some((proposer,receipt))=records.get(&id) {
                        if actor==*proposer||actor==current {Some(receipt.clone())}else{None}
                    } else if actor==current {
                        let command=rotation(id);let next=(id+1)%3;
                        let outcome=if epoch==u64::from(id)&&!used.contains(&next){current=next;epoch+=1;used.insert(next);SourceRotationOutcome::Committed}else{SourceRotationOutcome::Rejected};
                        let receipt=weaver_contracts::SourceRotationReceipt {operation_id:command.operation_id.clone(),digest:command.digest().expect("digest"),outcome,authority:weaver_contracts::SourceAuthority {epoch,identity:identity(current)}};
                        records.insert(id,(actor,receipt.clone()));Some(receipt)
                    } else {None};
                    prop_assert_eq!(ledger.rotate_source_authority(&identity(actor),&rotation(id)).ok(),expected);
                },
                1=>{let result=ledger.with_authenticated_source(&identity(actor),|l|l.stage_authority(&change()));prop_assert_eq!(result.is_ok(),actor==current);},
                2=>{
                    let result=ledger.with_authenticated_source(&identity(actor),|l|l.publish_authority(&change()));
                    prop_assert_eq!(result.is_ok(),actor==current);
                    if let Ok(receipt)=result {prop_assert_eq!(receipt.outcome,PublicationOutcome::Committed);publication=Some(receipt);}
                },
                _=>{drop(ledger);ledger=Ledger::open(&path).expect("restart");},
            }
            let actual=ledger.source_authority().expect("authority").expect("enrolled");prop_assert_eq!((actual.epoch,actual.identity),(epoch,identity(current)));
            prop_assert_eq!(ledger.held("f").expect("original exposure"),4);
            prop_assert_eq!(ledger.message_receipt("f","emit","m0").expect("observation").expect("original").state,weaver_contracts::MessageState::Unknown);
            if let Some(ref receipt)=publication {prop_assert_eq!(ledger.publication_receipt(&weaver_contracts::PublicationKey{operation_id:change().operation_id,digest:change().digest().expect("digest")}).expect("outcome"),Some(receipt.clone()));}
        }
    }
}
