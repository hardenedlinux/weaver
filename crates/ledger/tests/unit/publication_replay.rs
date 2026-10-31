#[path = "../../../policy/tests/support/publication_replay.rs"]
mod source;
use weaver_contracts::PublicationOutcome;
use weaver_ledger::Ledger;

#[test]
fn actual_spec_replay_registration_persists_before_original_final_cas() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("replay.db");
    let mut ledger = Ledger::open(&path).expect("store");
    let (change, mut review, mut evidence) = source::fixture();
    review.publication = ledger
        .stage_reviewed_authority(&change)
        .expect("original pending");
    review.parent = ledger
        .required_review_parent(&review.publication)
        .expect("actual parent");
    let original = review.clone();
    evidence["receipts"][0]["replay"]["decision"] = "deny".into();
    review.artifact = evidence.to_string();
    assert!(
        ledger
            .register_replay_checked_review(&change, &review)
            .is_err()
    );
    assert!(
        ledger
            .publication_review(&original.publication)
            .expect("read")
            .is_none()
    );
    assert!(
        ledger.publish_authority(&change).is_err(),
        "failed replay cannot resolve pending"
    );
    let digest = ledger
        .register_replay_checked_review(&change, &original)
        .expect("actual native schema-bound replay");
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("lost observation and restart");
    assert_eq!(
        ledger
            .publication_review(&original.publication)
            .expect("historical read"),
        Some(original.clone())
    );
    assert_eq!(
        ledger
            .register_replay_checked_review(&change, &original)
            .expect("exact retry"),
        digest
    );
    let receipt = ledger
        .publish_authority(&change)
        .expect("original deciding CAS");
    assert_eq!(receipt.outcome, PublicationOutcome::Committed);
    assert_eq!(
        ledger
            .publish_authority(&change)
            .expect("lost final response"),
        receipt
    );
}

#[test]
fn parent_advance_after_replay_validation_cannot_activate_the_old_candidate_or_refund() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("parent.db");
    let (mut ledger, c) = super::stream_properties::fixture(&path);
    ledger
        .enqueue_message(&super::stream_properties::message(&c, 0, 0, 1))
        .expect("original hold");
    let (mut change, mut review, _) = source::fixture();
    change.expected_revision = Some(0);
    review.publication = ledger.stage_reviewed_authority(&change).expect("stage");
    review.parent = ledger
        .required_review_parent(&review.publication)
        .expect("captured parent");
    weaver_policy::verify_publication_replay(&change, &review)
        .expect("earlier successful replay is inert");
    ledger
        .publish_typed(
            Some(0),
            include_str!("../../../../prod/policies/streaming/stream.cedar"),
            include_str!("../../../../prod/policies/streaming/schema.json"),
            2,
        )
        .expect("authoritative parent advance");
    assert!(
        ledger
            .register_replay_checked_review(&change, &review)
            .is_err()
    );
    assert_eq!(ledger.held("f").expect("held"), 4);
    assert_eq!(
        ledger
            .publish_authority(&change)
            .expect("original stale rejection")
            .outcome,
        PublicationOutcome::Rejected
    );
    assert_eq!(ledger.held("f").expect("unknown not refunded"), 4);
}
