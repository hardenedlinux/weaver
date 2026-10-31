#[path = "../../../policy/tests/support/publication_revision.rs"]
mod revision;
#[path = "../../../policy/tests/support/publication_replay.rs"]
mod source;
use weaver_contracts::PublicationOutcome;
use weaver_ledger::Ledger;

#[test]
fn candidate_only_replay_cannot_register_for_a_real_predecessor() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("unbound-before.db");
    let (mut ledger, _) = super::stream_properties::fixture(&path);
    let (mut change, mut review, _) = source::fixture();
    change.expected_revision = Some(0);
    review.publication = ledger.stage_reviewed_authority(&change).expect("stage");
    review.parent = ledger
        .required_review_parent(&review.publication)
        .expect("captured head");
    assert!(
        ledger
            .register_replay_checked_review(&change, &review)
            .is_err(),
        "candidate-only replay must not qualify a non-genesis predecessor"
    );
    assert!(
        ledger
            .publication_review(&review.publication)
            .expect("lookup")
            .is_none()
    );
    assert!(ledger.publish_authority(&change).is_err());
}

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
fn exact_revision_pair_replay_stays_historical_after_commit_and_parent_advance() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("pair.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    let (change, review, before) = revision::fixture(source::fixture());
    ledger
        .publish_typed(None, &before, &change.schema, 1)
        .expect("actual parent");
    assert_eq!(
        ledger.stage_reviewed_authority(&change).expect("stage"),
        review.publication
    );
    assert_eq!(
        ledger
            .required_review_parent(&review.publication)
            .expect("captured"),
        review.parent
    );
    let digest = ledger
        .register_replay_checked_review(&change, &review)
        .expect("exact two-image replay");
    ledger
        .close()
        .expect("natural close after lost observation");
    let mut ledger = Ledger::open(&path).expect("restart");
    assert_eq!(
        ledger
            .register_replay_checked_review(&change, &review)
            .expect("reconcile"),
        digest
    );
    let decision = ledger.publish_authority(&change).expect("original CAS");
    assert_eq!(decision.outcome, PublicationOutcome::Committed);
    ledger
        .publish_typed(Some(1), &before, &change.schema, 3)
        .expect("later head");
    assert_eq!(
        ledger
            .register_replay_checked_review(&change, &review)
            .expect("historical registration"),
        digest
    );
    assert_eq!(
        ledger
            .publish_authority(&change)
            .expect("historical result"),
        decision
    );
    assert_eq!(
        ledger
            .publish_typed(Some(2), &before, &change.schema, 4)
            .expect("history did not reset current head"),
        3
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
    let owner = ledger
        .claim_stream(weaver_ledger::StreamClaim {
            family: "f",
            node: "emit",
            destination: &c.destination,
            revision: 0,
            fence: 1,
        })
        .expect("original writer");
    let permit = ledger
        .consume_range(&owner, "m0", 8)
        .expect("original burn");
    ledger
        .write_range(&owner, permit, |_| {
            weaver_contracts::WriteObservation::Partial(2)
        })
        .expect("partial observation");
    let unknown = ledger
        .message_receipt("f", "emit", "m0")
        .expect("lookup")
        .expect("original receipt");
    assert_eq!(unknown.state, weaver_contracts::MessageState::Unknown);
    let (mut change, mut review, policy) = revision::fixture(source::fixture());
    ledger
        .publish_typed(Some(0), &policy, &change.schema, 2)
        .expect("actual named parent");
    change.expected_revision = Some(1);
    change.fence = 3;
    review.publication = ledger.stage_reviewed_authority(&change).expect("stage");
    review.parent = ledger
        .required_review_parent(&review.publication)
        .expect("captured parent");
    weaver_policy::verify_publication_replay(&change, &review, review.parent.as_ref())
        .expect("earlier successful replay is inert");
    ledger
        .publish_typed(
            Some(1),
            include_str!("../../../../prod/policies/streaming/stream.cedar"),
            include_str!("../../../../prod/policies/streaming/schema.json"),
            4,
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
    let after = ledger
        .message_receipt("f", "emit", "m0")
        .expect("lookup")
        .expect("original receipt retained");
    assert_eq!(
        serde_json::to_value(after).expect("receipt fields"),
        serde_json::to_value(unknown).expect("original fields")
    );
}
