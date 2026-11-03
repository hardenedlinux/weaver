// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use crate::review_fixture::{change, evidence, issuer, source};
use crate::{Ledger, persistence, publication_barrier};

#[test]
fn a_committed_association_recovers_but_a_historical_receipt_cannot_reactivate_it() {
    let temp = tempfile::tempdir().expect("dir");
    let path = temp.path().join("head.db");
    let mut l = Ledger::open(&path).expect("store");
    l.install_review_authority(&issuer(0)).expect("issuer");
    let p = change("original", None);
    let e = evidence(&mut l, &p);
    l.with_authenticated_source(&source(), |l| l.register_delta_review(&e))
        .expect("review");
    let original = l
        .with_authenticated_source(&source(), |l| l.publish_authority(&p))
        .expect("commit");
    publication_barrier::require_resolved(&l.connection).expect("current head");
    drop(l);
    let mut l = Ledger::open(&path).expect("restart");
    publication_barrier::require_resolved(&l.connection).expect("recovered association");
    l.install_review_authority(&issuer(1)).expect("new issuer");
    assert!(publication_barrier::require_resolved(&l.connection).is_err());
    assert_eq!(
        l.with_authenticated_source(&source(), |l| l.publish_authority(&p))
            .expect("original observation"),
        original
    );
    assert!(publication_barrier::require_resolved(&l.connection).is_err());
    let next = change("reviewed-next", Some(0));
    let e = evidence(&mut l, &next);
    l.with_authenticated_source(&source(), |l| l.register_delta_review(&e))
        .expect("review");
    l.with_authenticated_source(&source(), |l| l.publish_authority(&next))
        .expect("next");
    publication_barrier::require_resolved(&l.connection).expect("new reviewed head");
    l.publish_typed(Some(1), &p.policy, &p.schema, 2)
        .expect("trusted native API has no reviewed receipt");
    assert!(publication_barrier::require_resolved(&l.connection).is_err());
}

#[test]
fn association_failure_rolls_back_policy_outcome_and_pending_clear_together() {
    let temp = tempfile::tempdir().expect("dir");
    let mut l = Ledger::open(temp.path().join("atomic.db")).expect("store");
    l.install_review_authority(&issuer(0)).expect("issuer");
    let p = change("original", None);
    let e = evidence(&mut l, &p);
    l.with_authenticated_source(&source(), |l| l.register_delta_review(&e))
        .expect("review");
    persistence::script(&l.connection,"CREATE TRIGGER fail_head BEFORE INSERT ON authority_review_heads BEGIN SELECT RAISE(ABORT,'association failure'); END;").expect("fault");
    assert!(
        l.with_authenticated_source(&source(), |l| l.publish_authority(&p))
            .is_err()
    );
    assert!(
        crate::publication_review::parent(&l.connection)
            .expect("parent")
            .is_none()
    );
    assert!(
        l.publication_receipt(&e.review.publication)
            .expect("outcome")
            .is_none()
    );
    assert!(publication_barrier::require_resolved(&l.connection).is_err());
    persistence::script(&l.connection, "DROP TRIGGER fail_head").expect("repair");
    l.with_authenticated_source(&source(), |l| l.publish_authority(&p))
        .expect("same commit");
    publication_barrier::require_resolved(&l.connection).expect("complete commit");
    persistence::exec(&l.connection, "DELETE FROM review_authority", ()).expect("projection loss");
    assert!(publication_barrier::require_resolved(&l.connection).is_err());
}

#[test]
fn losing_verifier_metadata_cannot_downgrade_a_committed_served_profile() {
    for erase_mode in [false, true] {
        let temp = tempfile::tempdir().expect("dir");
        let path = temp.path().join("lost-metadata.db");
        let mut l = Ledger::open(&path).expect("store");
        l.install_review_authority(&issuer(0)).expect("root");
        let p = change("original", None);
        let proof = evidence(&mut l, &p);
        l.with_authenticated_source(&source(), |l| l.register_delta_review(&proof))
            .expect("review");
        l.with_authenticated_source(&source(), |l| l.publish_authority(&p))
            .expect("commit");
        publication_barrier::require_resolved(&l.connection).expect("positive control");
        persistence::script(
            &l.connection,
            "DELETE FROM review_authority; DELETE FROM review_keys;",
        )
        .expect("metadata loss");
        if erase_mode {
            persistence::exec(&l.connection, "DELETE FROM review_deployment", ())
                .expect("mode projection loss");
        }
        assert!(publication_barrier::require_resolved(&l.connection).is_err());
        drop(l);
        let mut l = Ledger::open(&path).expect("restart");
        assert!(crate::review_authority::current(&l.connection).is_err());
        assert!(
            l.install_review_authority(&issuer(0)).is_err(),
            "unknown floor cannot rebootstrap"
        );
        assert!(publication_barrier::require_resolved(&l.connection).is_err());
        assert!(
            l.publication_receipt(&proof.review.publication)
                .expect("historical outcome")
                .is_some()
        );
    }
}
