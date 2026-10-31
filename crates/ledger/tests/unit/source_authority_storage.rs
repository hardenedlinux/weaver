use crate::Ledger;
use weaver_contracts::{SourceIdentity, SourceRotation, SourceRotationOutcome, body_digest};
fn identity(n: u8) -> SourceIdentity {
    SourceIdentity {
        certificate_sha256: body_digest(&format!("certificate-{n}")),
        public_key_sha256: body_digest(&format!("public-key-{n}")),
        credential_sha256: body_digest("role"),
    }
}
fn command() -> SourceRotation {
    SourceRotation {
        operation_id: "handoff".into(),
        expected_epoch: 0,
        next: identity(1),
    }
}

#[test]
fn rotation_record_failure_rolls_back_key_retirement_and_epoch_together() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("fault.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("enroll");
    ledger.connection.execute_batch("CREATE TRIGGER handoff_failure BEFORE INSERT ON source_rotations BEGIN SELECT RAISE(ABORT,'injected handoff receipt failure'); END;").expect("fault");
    assert!(
        ledger
            .rotate_source_authority(&identity(0), &command())
            .is_err()
    );
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("reopen");
    assert_eq!(
        ledger
            .source_authority()
            .expect("read")
            .expect("present")
            .epoch,
        0
    );
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("original source not prematurely retired");
    ledger
        .connection
        .execute_batch("DROP TRIGGER handoff_failure")
        .expect("repair");
    assert_eq!(
        ledger
            .rotate_source_authority(&identity(0), &command())
            .expect("exact retry")
            .outcome,
        SourceRotationOutcome::Committed
    );
}

#[test]
fn missing_key_history_or_head_cannot_rebootstrap_from_configuration() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("prefix.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("initial");
    ledger
        .rotate_source_authority(&identity(0), &command())
        .expect("handoff");
    ledger
        .connection
        .execute("DELETE FROM source_keys WHERE epoch=0", [])
        .expect("truncate retained history");
    assert!(
        ledger
            .with_authenticated_source(&identity(1), |_| Ok(()))
            .is_err()
    );
    ledger
        .connection
        .execute("DELETE FROM source_authority", [])
        .expect("lose current projection");
    assert!(
        ledger
            .with_authenticated_source(&identity(0), |_| Ok(()))
            .is_err()
    );
    assert!(
        ledger
            .with_authenticated_source(&identity(1), |_| Ok(()))
            .is_err()
    );
}

#[test]
fn consistent_whole_store_rollback_remains_a_local_authority_counterexample() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("whole.db");
    let snapshot = temp.path().join("prior.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("initial");
    ledger.close().expect("natural close");
    std::fs::copy(&path, &snapshot).expect("consistent old image");
    let mut ledger = Ledger::open(&path).expect("current");
    ledger
        .rotate_source_authority(&identity(0), &command())
        .expect("handoff");
    ledger.close().expect("close all handles");
    std::fs::copy(&snapshot, &path).expect("restore all source records together");
    let mut ledger = Ledger::open(&path).expect("restored");
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("expected missing independent anti-rollback premise");
    assert_eq!(
        ledger
            .source_authority()
            .expect("read")
            .expect("old image")
            .epoch,
        0
    );
}
