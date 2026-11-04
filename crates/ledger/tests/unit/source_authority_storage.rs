// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::Ledger;
use proptest::{
    arbitrary::any, collection, prop_assert, prop_assert_eq, prop_oneof, proptest, strategy::Just,
    test_runner::Config,
};
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
fn residual_policy_schema_cannot_be_treated_as_an_empty_store_after_restart() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("residual.db");
    let ledger = Ledger::open(&path).expect("store");
    weaver_ledger::persistence::exec(
        &ledger.connection,
        "INSERT INTO authority_schema VALUES(1,?1)",
        weaver_ledger::persistence::params![
            (include_str!("../../../../prod/policies/streaming/schema.json")).to_owned()
        ],
    )
    .expect("retained schema projection");
    ledger.close().expect("close");
    let mut ledger = Ledger::open(&path).expect("restart");
    let mut called = false;
    assert!(
        ledger
            .with_authenticated_source(&identity(0), |_| {
                called = true;
                Ok(())
            })
            .is_err()
    );
    assert!(
        !called,
        "residual state reached a newly enrolled source callback"
    );
    assert!(ledger.source_authority().expect("unclaimed").is_none());
}

proptest! {
    #![proptest_config(Config::with_cases(64))]
    #[test]
    fn first_enrollment_uses_all_durable_tables_without_temporary_aliases(
        suffix in collection::vec(prop_oneof![Just('a'), Just('"'), Just('\''), Just(';'), Just('/'), Just(' '), Just('é')], 1..24),
        prefix in prop_oneof![Just("extension "), Just("sqliteX")],
        occupied in any::<bool>(), restart in any::<bool>(), shadow in any::<bool>(), enrolled in any::<bool>(),
    ) {
        let temp = tempfile::tempdir().expect("directory");
        let path = temp.path().join("catalog.db");
        let mut ledger = Ledger::open(&path).expect("store");
        if enrolled {
            ledger.with_authenticated_source(&identity(0), |_| Ok(())).expect("original binding");
        }
        let name = format!("{prefix}{}", suffix.into_iter().collect::<String>());
        // Turso quotes the independent fixture's identifier, rather than
        // repeating the production identifier-escaping implementation.
        let quoted: String = weaver_ledger::persistence::one(&ledger.connection, "SELECT quote(?1)", weaver_ledger::persistence::params![name.to_owned()], |row| row.get(0)).expect("quoted fixture name");
        weaver_ledger::persistence::script(&ledger.connection, &format!("CREATE TABLE {quoted} (retained INTEGER NOT NULL)")).expect("extension table");
        if occupied {
            weaver_ledger::persistence::exec(&ledger.connection, &format!("INSERT INTO main.{quoted} VALUES(1)"), ()).expect("retained row");
        }
        if restart {
            ledger.close().expect("close");
            ledger = Ledger::open(&path).expect("reopen");
        }
        if shadow {
            weaver_ledger::persistence::script(&ledger.connection, &format!("CREATE TEMP TABLE {quoted} (retained INTEGER NOT NULL)")).expect("temporary alias");
            if !occupied {
                weaver_ledger::persistence::exec(&ledger.connection, &format!("INSERT INTO temp.{quoted} VALUES(1)"), ()).expect("nondurable row");
            }
        }
        let expected = enrolled || !occupied;
        let mut calls = 0;
        let result = ledger.with_authenticated_source(&identity(0), |_| { calls += 1; Ok(()) });
        prop_assert_eq!(result.is_ok(), expected);
        prop_assert_eq!(calls, if expected { 1 } else { 0 });
        let rows: i64 = weaver_ledger::persistence::one(&ledger.connection, &format!("SELECT COUNT(*) FROM main.{quoted}"), (), |row| row.get(0)).expect("original rows");
        prop_assert_eq!(rows, if occupied { 1 } else { 0 });
        ledger.close().expect("close after admission");
        let mut ledger = Ledger::open(&path).expect("durable outcome");
        prop_assert_eq!(ledger.source_authority().expect("source binding").is_some(), expected);
        prop_assert!(ledger.with_authenticated_source(&identity(1), |_| Ok(())).is_err());
    }
}

#[test]
fn committed_writer_before_enrollment_cannot_be_hidden_by_an_old_empty_read() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("writer.db");
    let mut ledger = Ledger::open(&path).expect("store");
    let mut writer = weaver_ledger::persistence::Session::open(&path).expect("other owner");
    let tx = weaver_ledger::persistence::begin(&mut writer).expect("writer owns serialization");
    weaver_ledger::persistence::script(
        &tx,
        "CREATE TABLE main.future_projection (retained INTEGER NOT NULL);\n\
         INSERT INTO main.future_projection VALUES(1);",
    )
    .expect("new pending projection and catalog entry");
    let (entered, observed) = std::sync::mpsc::channel();
    let worker = std::thread::spawn(move || {
        entered.send(()).expect("attempt");
        let mut called = false;
        let denied = ledger
            .with_authenticated_source(&identity(0), |_| {
                called = true;
                Ok(())
            })
            .is_err();
        (denied, called, ledger.source_authority().expect("outcome"))
    });
    observed.recv().expect("worker admitted to test");
    tx.commit().expect("prior writer commits");
    let (denied, called, authority) = worker.join().expect("worker completion");
    assert!(denied && !called && authority.is_none());
}

#[test]
fn callback_failure_after_enrollment_does_not_allow_a_replacement_identity() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("reply.db");
    let mut ledger = Ledger::open(&path).expect("store");
    let result: weaver_contracts::Result<()> =
        ledger.with_authenticated_source(&identity(0), |_| {
            Err(weaver_contracts::Error::Conflict(
                "injected caller failure after enrollment",
            ))
        });
    assert!(result.is_err());
    ledger.close().expect("close");
    let mut ledger = Ledger::open(&path).expect("restart");
    assert!(
        ledger
            .with_authenticated_source(&identity(1), |_| Ok(()))
            .is_err()
    );
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("original recovery");
    assert_eq!(
        ledger
            .source_authority()
            .expect("view")
            .expect("binding")
            .epoch,
        0
    );
}

#[test]
fn rotation_record_failure_rolls_back_key_retirement_and_epoch_together() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("fault.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger
        .with_authenticated_source(&identity(0), |_| Ok(()))
        .expect("enroll");
    weaver_ledger::persistence::script(&ledger.connection, "CREATE TRIGGER handoff_failure BEFORE INSERT ON source_rotations BEGIN SELECT RAISE(ABORT,'injected handoff receipt failure'); END;").expect("fault");
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
    weaver_ledger::persistence::script(&ledger.connection, "DROP TRIGGER handoff_failure")
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
    weaver_ledger::persistence::exec(
        &ledger.connection,
        "DELETE FROM source_keys WHERE epoch=0",
        (),
    )
    .expect("truncate retained history");
    assert!(
        ledger
            .with_authenticated_source(&identity(1), |_| Ok(()))
            .is_err()
    );
    weaver_ledger::persistence::exec(&ledger.connection, "DELETE FROM source_authority", ())
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
    crate::snapshot::copy_closed(&path, &snapshot).expect("consistent old image");
    let mut ledger = Ledger::open(&path).expect("current");
    ledger
        .rotate_source_authority(&identity(0), &command())
        .expect("handoff");
    ledger.close().expect("close all handles");
    crate::snapshot::copy_closed(&snapshot, &path).expect("restore all source records together");
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
