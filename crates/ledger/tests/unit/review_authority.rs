// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use super::current;
use crate::Ledger;
use weaver_contracts::ReviewAuthority;
fn authority(epoch: u64) -> ReviewAuthority {
    ReviewAuthority {
        audience: "test-gateway".into(),
        epoch,
        public_key: "4".repeat(64),
        allow_expansion: false,
    }
}
#[test]
fn deployment_metadata_is_immutable_within_epoch_and_recovers_its_floor() {
    let temp = tempfile::tempdir().expect("directory");
    let path = temp.path().join("root.db");
    let mut ledger = Ledger::open(&path).expect("store");
    let original = authority(0);
    ledger
        .install_review_authority(&original)
        .expect("provision");
    ledger
        .install_review_authority(&original)
        .expect("idempotent");
    let mut replacement = original.clone();
    replacement.public_key = "5".repeat(64);
    assert!(ledger.install_review_authority(&replacement).is_err());
    let next = authority(1);
    ledger.install_review_authority(&next).expect("advance");
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert_eq!(current(&ledger.connection).expect("read"), Some(next));
    assert!(ledger.install_review_authority(&original).is_err());
    let mut other = authority(2);
    other.audience = "other-gateway".into();
    assert!(ledger.install_review_authority(&other).is_err());
}
#[test]
fn failed_native_update_retains_the_complete_previous_configuration() {
    let temp = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(temp.path().join("atomic.db")).expect("store");
    let original = authority(0);
    ledger
        .install_review_authority(&original)
        .expect("provision");
    crate::persistence::script(&ledger.connection,"CREATE TRIGGER refuse_root BEFORE UPDATE ON review_authority BEGIN SELECT RAISE(ABORT,'root fault'); END;").expect("fault");
    assert!(ledger.install_review_authority(&authority(1)).is_err());
    assert_eq!(current(&ledger.connection).expect("read"), Some(original));
}
#[test]
fn authenticated_source_role_cannot_provision_a_deployment_key() {
    let temp = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(temp.path().join("role.db")).expect("store");
    let source = weaver_contracts::SourceIdentity {
        certificate_sha256: "1".repeat(64),
        public_key_sha256: "2".repeat(64),
        credential_sha256: "3".repeat(64),
    };
    ledger
        .with_authenticated_source(&source, |_| Ok(()))
        .expect("source enrollment");
    ledger
        .install_review_authority(&authority(0))
        .expect("host provision");
    assert!(
        ledger
            .with_authenticated_source(&source, |l| l.install_review_authority(&authority(1)))
            .is_err()
    );
    assert_eq!(
        current(&ledger.connection).expect("read"),
        Some(authority(0))
    );
}

#[test]
fn missing_projection_cannot_reopen_an_old_key_epoch() {
    let temp = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(temp.path().join("floor.db")).expect("store");
    ledger
        .install_review_authority(&authority(0))
        .expect("first");
    ledger
        .install_review_authority(&authority(1))
        .expect("advance");
    crate::persistence::exec(&ledger.connection, "DELETE FROM review_authority", ())
        .expect("projection loss");
    assert!(current(&ledger.connection).is_err());
    assert!(ledger.install_review_authority(&authority(0)).is_err());
    ledger
        .install_review_authority(&authority(1))
        .expect("restore exact retained floor");
    assert_eq!(
        current(&ledger.connection).expect("current"),
        Some(authority(1))
    );
}
