// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::stream_properties::{fixture, message};
use proptest::{collection, prop_assert_eq, proptest, test_runner::Config};
use weaver_contracts::{
    AuthorityParent, Publication, PublicationOutcome, PublicationReview, body_digest,
};
use weaver_ledger::{Ledger, StreamClaim};

const POLICY: &str = include_str!("../../../../prod/policies/streaming/stream.cedar");
const SCHEMA: &str = include_str!("../../../../prod/policies/streaming/schema.json");
fn proposal(id: &str, parent: Option<u64>) -> Publication {
    Publication {
        operation_id: id.into(),
        expected_revision: parent,
        fence: 1,
        policy: POLICY.into(),
        schema: SCHEMA.into(),
    }
}
fn review(
    ledger: &Ledger,
    key: &weaver_contracts::PublicationKey,
    artifact: u8,
) -> PublicationReview {
    PublicationReview {
        publication: key.clone(),
        parent: ledger.required_review_parent(key).expect("captured parent"),
        artifact: format!("trusted-host-fixture-{artifact}"),
    }
}

#[test]
fn missing_review_cannot_downgrade_and_original_registration_survives_reply_loss() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("review.db");
    let (mut ledger, c) = fixture(&path);
    ledger
        .enqueue_message(&message(&c, 0, 0, 1))
        .expect("original hold");
    let change = proposal("reviewed", Some(0));
    let key = ledger.stage_reviewed_authority(&change).expect("stage");
    ledger
        .stage_authority(&change)
        .expect("legacy replay cannot downgrade");
    assert!(ledger.publish_authority(&change).is_err());
    assert!(ledger.publication_receipt(&key).expect("unknown").is_none());
    let original = review(&ledger, &key, 0);
    let digest = ledger
        .register_approved_review(&original)
        .expect("trusted host registration");
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart after lost reply");
    assert_eq!(
        ledger.publication_review(&key).expect("read"),
        Some(original.clone())
    );
    assert_eq!(
        ledger
            .register_approved_review(&original)
            .expect("same registration"),
        digest
    );
    assert!(
        ledger
            .register_approved_review(&review(&ledger, &key, 1))
            .is_err()
    );
    let committed = ledger.publish_authority(&change).expect("final CAS");
    assert_eq!(committed.outcome, PublicationOutcome::Committed);
    let later = proposal("later", Some(1));
    ledger.publish_authority(&later).expect("advance");
    assert_eq!(
        ledger
            .stage_reviewed_authority(&change)
            .expect("no pending resurrection"),
        key
    );
    assert_eq!(
        ledger
            .register_approved_review(&original)
            .expect("historical exact observation"),
        digest
    );
    assert_eq!(
        ledger.publish_authority(&change).expect("original outcome"),
        committed
    );
    assert_eq!(ledger.held("f").expect("unknown budget"), 4);
}

#[test]
fn parent_change_records_original_rejection_and_keeps_sibling_pending() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("parent.db");
    let (mut ledger, c) = fixture(&path);
    ledger.enqueue_message(&message(&c, 0, 0, 1)).expect("hold");
    let change = proposal("reviewed", Some(0));
    let key = ledger.stage_reviewed_authority(&change).expect("stage");
    let original = review(&ledger, &key, 0);
    ledger.register_approved_review(&original).expect("review");
    let sibling = proposal("sibling", Some(0));
    ledger.stage_authority(&sibling).expect("sibling");
    ledger
        .publish_typed(Some(0), POLICY, SCHEMA, 1)
        .expect("independent parent changes");
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("old worker resumes");
    assert_eq!(
        ledger
            .publish_authority(&change)
            .expect("terminal stale CAS")
            .outcome,
        PublicationOutcome::Rejected
    );
    assert_eq!(
        ledger.publication_review(&key).expect("retained artifact"),
        Some(original)
    );
    assert!(
        ledger
            .claim_stream(StreamClaim {
                family: "f",
                node: "emit",
                destination: &c.destination,
                revision: 1,
                fence: 1
            })
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("hold"), 4);
    assert_eq!(
        ledger
            .publish_authority(&sibling)
            .expect("resolve only sibling")
            .outcome,
        PublicationOutcome::Rejected
    );
    assert!(
        ledger
            .claim_stream(StreamClaim {
                family: "f",
                node: "emit",
                destination: &c.destination,
                revision: 1,
                fence: 1
            })
            .is_ok()
    );
}

#[test]
fn genesis_parent_is_distinct_from_unknown_requirement_and_no_retroactive_review() {
    let temp = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(temp.path().join("genesis.db")).expect("open");
    let change = proposal("genesis", None);
    let key = ledger.stage_reviewed_authority(&change).expect("stage");
    assert_eq!(
        ledger.required_review_parent(&key).expect("known genesis"),
        None
    );
    let mut forged = key.clone();
    forged.operation_id = "unknown".into();
    assert!(ledger.required_review_parent(&forged).is_err());
    assert!(ledger.publish_authority(&change).is_err());
    ledger
        .register_approved_review(&review(&ledger, &key, 0))
        .expect("genesis review");
    assert_eq!(
        ledger.publish_authority(&change).expect("genesis").outcome,
        PublicationOutcome::Committed
    );
    let old = proposal("unreviewed", Some(0));
    ledger
        .publish_authority(&old)
        .expect("retained trust profile");
    assert!(ledger.stage_reviewed_authority(&old).is_err());
}

#[derive(Clone, Copy, Debug)]
enum Command {
    LegacyStage,
    Register(u8),
    Publish,
    AdvanceParent,
    Restart,
    Substitute,
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn reviewed_prefixes_match_an_independent_model(actions in collection::vec((0u8..6,0u8..2),1..28)) {
        let temp=tempfile::tempdir().expect("directory");let path=temp.path().join("trace.db");
        let (mut ledger,c)=fixture(&path);ledger.enqueue_message(&message(&c,0,0,1)).expect("original claim");
        let original_owner=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&c.destination,revision:0,fence:1}).expect("original owner");
        let range=ledger.consume_range(&original_owner,"m0",8).expect("original consumed range");
        ledger.write_range(&original_owner,range,|_|weaver_contracts::WriteObservation::Partial(3)).expect("partial observation");
        let change=proposal("reviewed",Some(0));let key=ledger.stage_reviewed_authority(&change).expect("required prefix");
        let captured=AuthorityParent {revision:0,fence:1,policy_digest:body_digest(POLICY),schema_digest:None};
        prop_assert_eq!(ledger.required_review_parent(&key).expect("parent"),Some(captured.clone()));
        let mut revision=0;let mut registered=None;let mut decided=None;
        for (action,value) in actions {
            let command=match action {0=>Command::LegacyStage,1=>Command::Register(value),2=>Command::Publish,3=>Command::AdvanceParent,4=>Command::Restart,_=>Command::Substitute};
            match command {
                Command::LegacyStage=>{ledger.stage_authority(&change).expect("replay");},
                Command::Register(artifact)=>{
                    let approved=PublicationReview {publication:key.clone(),parent:Some(captured.clone()),artifact:format!("trusted-host-fixture-{artifact}")};
                    let allowed=registered==Some(artifact) || (registered.is_none() && decided.is_none() && revision==0);
                    prop_assert_eq!(ledger.register_approved_review(&approved).is_ok(),allowed);
                    if allowed {registered=Some(artifact);}
                },
                Command::Publish=>{
                    let result=ledger.publish_authority(&change);
                    if let Some(outcome)=decided {prop_assert_eq!(result.expect("immutable replay").outcome,outcome);}
                    else if revision!=0 {decided=Some(PublicationOutcome::Rejected);prop_assert_eq!(result.expect("stale rejection").outcome,PublicationOutcome::Rejected);}
                    else if registered.is_some() {decided=Some(PublicationOutcome::Committed);revision=1;prop_assert_eq!(result.expect("approved commit").outcome,PublicationOutcome::Committed);}
                    else {prop_assert_eq!(result.is_err(),true);}
                },
                Command::AdvanceParent=>{ledger.publish_typed(Some(revision),POLICY,SCHEMA,1).expect("trusted host update");revision+=1;},
                Command::Restart=>{drop(ledger);ledger=Ledger::open(&path).expect("restart");},
                Command::Substitute=>{let mut rebound=change.clone();rebound.fence=2;prop_assert_eq!(ledger.publish_authority(&rebound).is_err(),true);},
            }
            prop_assert_eq!(ledger.publication_receipt(&key).expect("outcome").map(|r|r.outcome),decided);
            prop_assert_eq!(ledger.publication_review(&key).expect("review").map(|r|r.artifact),registered.map(|a|format!("trusted-host-fixture-{a}")));
            let ownership=ledger.claim_stream(StreamClaim{family:"f",node:"emit",destination:&c.destination,revision,fence:1});
            prop_assert_eq!(ownership.is_ok(),false,"the partial original prefix blocks a new owner even after reviewed publication resolves");
            prop_assert_eq!(ledger.consume_range(&original_owner,"m0",8).is_err(),true,"old custody cannot reconstruct the uncertain tail");
            let exposure=ledger.message_receipt("f","emit","m0").expect("observation").expect("original message");
            prop_assert_eq!(exposure.state,weaver_contracts::MessageState::Unknown);
            prop_assert_eq!((exposure.cursor,exposure.reserved),(0,4));
            prop_assert_eq!(ledger.held("f").expect("unknown hold"),4);
        }
    }
}
