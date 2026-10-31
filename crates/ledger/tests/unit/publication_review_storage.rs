use crate::Ledger;
use std::sync::{Arc, Barrier};
use weaver_contracts::{Publication, PublicationOutcome, PublicationReview};

const POLICY: &str = include_str!("../../../../prod/policies/provider/provider.cedar");
const SCHEMA: &str = include_str!("../../../../prod/policies/provider/schema.json");
fn proposal() -> Publication {
    Publication {
        operation_id: "reviewed".into(),
        expected_revision: Some(0),
        fence: 1,
        policy: POLICY.into(),
        schema: SCHEMA.into(),
    }
}
fn prepare(path: &std::path::Path) -> (Ledger, PublicationReview) {
    let mut ledger = Ledger::open(path).expect("store");
    ledger
        .publish_typed(None, POLICY, SCHEMA, 1)
        .expect("original parent");
    let publication = ledger.stage_reviewed_authority(&proposal()).expect("stage");
    let parent = ledger.required_review_parent(&publication).expect("parent");
    (
        ledger,
        PublicationReview {
            publication,
            parent,
            artifact: "upstream-approved-fixture".into(),
        },
    )
}

#[test]
fn staged_requirement_and_registration_failures_are_atomic() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("fault.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .publish_typed(None, POLICY, SCHEMA, 1)
        .expect("parent");
    ledger.connection.execute_batch("CREATE TRIGGER stage_failure BEFORE INSERT ON authority_pending BEGIN SELECT RAISE(ABORT,'stage failure'); END;").expect("fault");
    assert!(ledger.stage_reviewed_authority(&proposal()).is_err());
    let count: i64 = ledger
        .connection
        .query_row(
            "SELECT COUNT(*) FROM authority_review_requirements",
            [],
            |r| r.get(0),
        )
        .expect("count");
    assert_eq!(count, 0, "failed stage left a detached requirement");
    ledger
        .connection
        .execute_batch("DROP TRIGGER stage_failure")
        .expect("repair");
    let key = ledger.stage_reviewed_authority(&proposal()).expect("stage");
    let review = PublicationReview {
        parent: ledger.required_review_parent(&key).expect("parent"),
        publication: key.clone(),
        artifact: "approved fixture".into(),
    };
    ledger.connection.execute_batch("CREATE TRIGGER review_failure BEFORE INSERT ON authority_reviews BEGIN SELECT RAISE(ABORT,'review failure'); END;").expect("fault");
    assert!(ledger.register_approved_review(&review).is_err());
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(ledger.publication_review(&key).expect("read").is_none());
    assert!(ledger.publish_authority(&proposal()).is_err());
    crate::publication_barrier::require_resolved(&ledger.connection)
        .expect_err("retained original pending");
    ledger
        .connection
        .execute_batch("DROP TRIGGER review_failure")
        .expect("repair");
    ledger
        .register_approved_review(&review)
        .expect("recover exact registration");
    assert_eq!(
        ledger
            .publish_authority(&proposal())
            .expect("commit")
            .outcome,
        PublicationOutcome::Committed
    );
}

#[test]
fn same_revision_parent_replacement_and_artifact_corruption_block_final_commit() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("corruption.db");
    let (mut ledger, review) = prepare(&path);
    ledger.register_approved_review(&review).expect("register");
    ledger
        .connection
        .execute(
            "UPDATE authority SET policy=?1",
            [format!("{POLICY}\n//changed parent bytes")],
        )
        .expect("corrupt same ordinal");
    assert!(ledger.publish_authority(&proposal()).is_err());
    assert!(
        ledger
            .publication_receipt(&review.publication)
            .expect("read")
            .is_none()
    );
    ledger
        .connection
        .execute("UPDATE authority SET policy=?1", [POLICY])
        .expect("restore exact image");
    ledger
        .connection
        .execute(
            "UPDATE authority_reviews SET artifact_digest=?1",
            ["0".repeat(64)],
        )
        .expect("corrupt review projection");
    assert!(ledger.publication_review(&review.publication).is_err());
    assert!(ledger.publish_authority(&proposal()).is_err());
    assert!(
        ledger
            .publication_receipt(&review.publication)
            .expect("read")
            .is_none()
    );
    // This check detects divergent bytes. It cannot detect a consistent rollback
    // of all requirements, outcomes and authority to one older valid snapshot.
    crate::publication_barrier::require_resolved(&ledger.connection)
        .expect_err("unknown remains held");
}

#[test]
fn concurrent_different_artifacts_have_one_immutable_winner_after_restart() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("race.db");
    let (mut ledger, first) = prepare(&path);
    let mut second = first.clone();
    second.artifact = "different approval".into();
    let gate = Arc::new(Barrier::new(2));
    let child_gate = gate.clone();
    let child_path = path.clone();
    let other = second.clone();
    let child = std::thread::spawn(move || {
        let mut old_worker = Ledger::open(child_path).expect("worker");
        child_gate.wait();
        old_worker.register_approved_review(&other)
    });
    gate.wait();
    let left = ledger.register_approved_review(&first);
    let right = child.join().expect("join");
    assert_ne!(left.is_ok(), right.is_ok());
    let winner = if left.is_ok() { first } else { second };
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert_eq!(
        ledger
            .publication_review(&winner.publication)
            .expect("read"),
        Some(winner.clone())
    );
    assert_eq!(
        ledger
            .register_approved_review(&winner)
            .expect("lost reply recovery"),
        winner.digest().expect("digest")
    );
    assert_eq!(
        ledger
            .publish_authority(&proposal())
            .expect("commit")
            .outcome,
        PublicationOutcome::Committed
    );
}

#[test]
fn stage_review_requirement_and_legacy_final_cas_have_one_serial_order() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("stage-race.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .publish_typed(None, POLICY, SCHEMA, 1)
        .expect("parent");
    let gate = Arc::new(Barrier::new(2));
    let child_gate = gate.clone();
    let child_path = path.clone();
    let child = std::thread::spawn(move || {
        let mut old_worker = Ledger::open(child_path).expect("worker");
        child_gate.wait();
        old_worker.stage_reviewed_authority(&proposal())
    });
    gate.wait();
    let publication = ledger.publish_authority(&proposal());
    let stage = child.join().expect("join");
    assert_ne!(
        publication.is_ok(),
        stage.is_ok(),
        "both branches cannot succeed"
    );
    if let Ok(key) = stage {
        assert!(ledger.publication_receipt(&key).expect("read").is_none());
        assert!(ledger.publish_authority(&proposal()).is_err());
    } else {
        assert_eq!(
            publication.expect("earlier commit").outcome,
            PublicationOutcome::Committed
        );
        assert!(ledger.stage_reviewed_authority(&proposal()).is_err());
    }
}

// Expected limitation of this trusted-host local profile, not an independent
// registry recovery guarantee. Restore only after closing all SQLite owners.
#[test]
fn consistent_snapshot_rollback_can_replace_local_registered_artifact_counterexample() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("rollback.db");
    let snapshot = temp.path().join("before-registration.db");
    let (mut ledger, original) = prepare(&path);
    drop(ledger);
    std::fs::copy(&path, &snapshot).expect("closed pre-registration snapshot");
    ledger = Ledger::open(&path).expect("original owner recovery");
    ledger
        .register_approved_review(&original)
        .expect("registration whose reply is lost");
    drop(ledger);
    ledger = Ledger::open(&path).expect("process restart");
    assert_eq!(
        ledger
            .publication_review(&original.publication)
            .expect("durable read"),
        Some(original.clone())
    );
    let mut replacement = original.clone();
    replacement.artifact = "different upstream approval after rollback".into();
    assert!(
        ledger.register_approved_review(&replacement).is_err(),
        "ordinary restart must retain the original artifact"
    );
    drop(ledger);
    std::fs::copy(&snapshot, &path).expect("restore consistent old database");
    ledger = Ledger::open(&path).expect("snapshot recovery");
    assert!(
        ledger
            .publication_review(&original.publication)
            .expect("rolled-back read")
            .is_none()
    );
    assert!(
        ledger.publish_authority(&proposal()).is_err(),
        "missing review must still block final CAS"
    );
    crate::publication_barrier::require_resolved(&ledger.connection)
        .expect_err("original pending survives this snapshot");
    ledger
        .register_approved_review(&replacement)
        .expect("expected gap: no independent registry prefix rejects replacement");
    assert_eq!(
        ledger
            .publication_review(&original.publication)
            .expect("replacement read"),
        Some(replacement)
    );
    assert_eq!(
        ledger
            .publish_authority(&proposal())
            .expect("trusted-host local commit")
            .outcome,
        PublicationOutcome::Committed
    );
}
