// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::registered;
use crate::Ledger;
use crate::review_fixture::{change, evidence, issuer, source};
#[test]
fn registry_rows_are_atomic_and_original_evidence_is_recovered() {
    let temp = tempfile::tempdir().expect("dir");
    let path = temp.path().join("registry.db");
    let mut ledger = Ledger::open(&path).expect("store");
    ledger.install_review_authority(&issuer(0)).expect("issuer");
    let p = change("original", None);
    let e = evidence(&mut ledger, &p);
    crate::persistence::script(&ledger.connection,"CREATE TRIGGER fail_delta BEFORE INSERT ON authority_delta_reviews BEGIN SELECT RAISE(ABORT,'delta failure'); END;").expect("fault");
    assert!(
        ledger
            .with_authenticated_source(&source(), |l| l.register_delta_review(&e))
            .is_err()
    );
    assert!(
        ledger
            .publication_review(&e.review.publication)
            .expect("review")
            .is_none()
    );
    crate::persistence::script(&ledger.connection, "DROP TRIGGER fail_delta").expect("repair");
    ledger
        .with_authenticated_source(&source(), |l| l.register_delta_review(&e))
        .expect("commit whose acknowledgment is discarded");
    drop(ledger);
    let mut ledger = Ledger::open(&path).expect("restart");
    assert_eq!(
        ledger
            .with_authenticated_source(&source(), |l| l.register_delta_review(&e))
            .expect("same outcome"),
        e.review.digest().expect("digest")
    );
    assert_eq!(
        registered(&ledger.connection, &e.review.publication, 0, 0).expect("read"),
        Some(e.clone())
    );
    let count: i64 = crate::persistence::one(
        &ledger.connection,
        "SELECT COUNT(*) FROM authority_publications",
        (),
        |r| r.get(0),
    )
    .expect("count");
    assert_eq!(count, 0, "registration must not publish");
}
#[test]
fn stale_source_issuer_and_parent_cannot_register() {
    let temp = tempfile::tempdir().expect("dir");
    let mut ledger = Ledger::open(temp.path().join("stale.db")).expect("store");
    ledger.install_review_authority(&issuer(0)).expect("issuer");
    let p = change("original", None);
    let e = evidence(&mut ledger, &p);
    let mut forged = e.clone();
    forged.review.artifact.push(' ');
    assert!(
        ledger
            .with_authenticated_source(&source(), |l| l.register_delta_review(&forged))
            .is_err()
    );
    ledger.install_review_authority(&issuer(1)).expect("revoke");
    assert!(
        ledger
            .with_authenticated_source(&source(), |l| l.register_delta_review(&e))
            .is_err()
    );
    let e = evidence(&mut ledger, &p);
    ledger
        .publish_typed(None, &p.policy, &p.schema, 1)
        .expect("other parent");
    assert!(
        ledger
            .with_authenticated_source(&source(), |l| l.register_delta_review(&e))
            .is_err()
    );
    assert!(
        ledger
            .publication_review(&e.review.publication)
            .expect("read")
            .is_none()
    );
}

#[test]
fn publication_rechecks_the_issuer_and_keeps_the_original_pending_intent() {
    let temp = tempfile::tempdir().expect("dir");
    let path = temp.path().join("commit.db");
    let mut l = Ledger::open(&path).expect("store");
    l.install_review_authority(&issuer(0)).expect("issuer");
    let p = change("original", None);
    let e = evidence(&mut l, &p);
    l.with_authenticated_source(&source(), |l| l.register_delta_review(&e))
        .expect("register");
    l.install_review_authority(&issuer(1))
        .expect("rotate verifier");
    assert!(
        l.with_authenticated_source(&source(), |l| l.publish_authority(&p))
            .is_err()
    );
    assert!(
        l.publication_receipt(&e.review.publication)
            .expect("receipt")
            .is_none()
    );
    assert!(
        crate::publication_review::parent(&l.connection)
            .expect("parent")
            .is_none()
    );
    assert!(crate::publication_barrier::require_resolved(&l.connection).is_err());
    let e = evidence(&mut l, &p);
    l.with_authenticated_source(&source(), |l| l.register_delta_review(&e))
        .expect("new current approval");
    let receipt = l
        .with_authenticated_source(&source(), |l| l.publish_authority(&p))
        .expect("commit whose response is discarded");
    drop(l);
    let mut l = Ledger::open(&path).expect("restart");
    assert_eq!(
        l.with_authenticated_source(&source(), |l| l.publish_authority(&p))
            .expect("exact original outcome"),
        receipt
    );
}

#[test]
fn an_unsigned_trusted_host_record_cannot_publish_in_the_deployment_profile() {
    let temp = tempfile::tempdir().expect("dir");
    let mut l = Ledger::open(temp.path().join("unsigned.db")).expect("store");
    l.install_review_authority(&issuer(0)).expect("issuer");
    let p = change("original", None);
    let e = evidence(&mut l, &p);
    l.with_authenticated_source(&source(), |l| l.register_approved_review(&e.review))
        .expect("native host registration");
    assert!(
        l.with_authenticated_source(&source(), |l| l.publish_authority(&p))
            .is_err()
    );
    assert!(
        crate::publication_review::parent(&l.connection)
            .expect("parent")
            .is_none()
    );
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(32))]
    #[test]
    fn arbitrary_review_rotation_restart_and_late_cas_schedules_preserve_one_outcome(
        schedule in proptest::collection::vec(0u8..5,1..24)
    ) {
        let temp=tempfile::tempdir().expect("dir");let path=temp.path().join("property.db");
        let mut l=Ledger::open(&path).expect("store");let mut epoch=0;
        l.install_review_authority(&issuer(epoch)).expect("issuer");let p=change("original",None);
        let mut proof=evidence(&mut l,&p);let mut approved=std::collections::BTreeSet::new();
        let mut committed=None;
        for event in schedule {
            match event {
                0=>{epoch+=1;l.install_review_authority(&issuer(epoch)).expect("rotate");}
                1=>{
                    let result=l.with_authenticated_source(&source(),|l|l.register_delta_review(&proof));
                    let allowed=proof.reviewer_epoch==epoch && (committed.is_none() || approved.contains(&epoch));
                    proptest::prop_assert_eq!(result.is_ok(),allowed);
                    if allowed {approved.insert(epoch);}
                }
                2=>{
                    let result=l.with_authenticated_source(&source(),|l|l.publish_authority(&p));
                    let allowed=committed.is_some()||approved.contains(&epoch);
                    proptest::prop_assert_eq!(result.is_ok(),allowed);
                    if allowed && committed.is_none(){committed=Some(epoch);}
                }
                3=>{drop(l);l=Ledger::open(&path).expect("restart");}
                _=>{if committed.is_none(){proof=evidence(&mut l,&p);}}
            }
            proptest::prop_assert_eq!(l.publication_receipt(&proof.review.publication).expect("observe").is_some(),committed.is_some());
            proptest::prop_assert_eq!(crate::publication_barrier::require_resolved(&l.connection).is_ok(),committed==Some(epoch));
        }
    }
}
