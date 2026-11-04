// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Binding negatives only; actual solver qualification is integration-owned.
use super::verify_qualified_delta;
use weaver_contracts::{
    AuthorityParent, DeltaDisposition, DeltaReview, Publication, PublicationKey, PublicationReview,
    QualifiedDeltaCatalog, QualifiedDeltaEntry, body_digest,
};
fn fixture() -> (Publication, DeltaReview, String) {
    let schema = include_str!("../../../../prod/policies/provider/schema.json").to_string();
    let before = "permit(principal,action,resource);".to_string();
    let after = "forbid(principal,action,resource);".to_string();
    let p = Publication {
        operation_id: "revoke".into(),
        expected_revision: Some(0),
        fence: 2,
        policy: after.clone(),
        schema: schema.clone(),
    };
    let parent = AuthorityParent {
        revision: 0,
        fence: 1,
        policy_digest: body_digest(&before),
        schema_digest: Some(body_digest(&schema)),
    };
    let catalog = QualifiedDeltaCatalog {
        engine: "cedar-poo-spec.exact-error-free-allow".into(),
        qualification: "solver-checked".into(),
        entries: vec![QualifiedDeltaEntry {
            name: "revoke".into(),
            before_policy: before,
            after_policy: after,
            schema,
            epoch: 0,
            environments: 3,
            gains: 0,
            losses: 3,
            classification: "loss-only".into(),
        }],
    };
    let delta = serde_json::to_string(&catalog).expect("catalog");
    let pin = body_digest(&delta);
    let e = DeltaReview {
        review: PublicationReview {
            publication: PublicationKey {
                operation_id: p.operation_id.clone(),
                digest: p.digest().expect("digest"),
            },
            parent: Some(parent),
            artifact: "revoke".into(),
        },
        audience: "gateway".into(),
        reviewer_epoch: 0,
        source_epoch: 0,
        source_identity_digest: "1".repeat(64),
        disposition: DeltaDisposition::NoExecutionGain,
        delta,
        signature: "0".repeat(128),
    };
    (p, e, pin)
}
#[test]
fn deployment_pin_and_original_parent_are_both_required() {
    let (p, e, pin) = fixture();
    verify_qualified_delta(&pin, &p, e.review.parent.as_ref(), &e).expect("binding fixture");
    let mut parent = e.review.parent.clone().expect("parent");
    parent.revision = 1;
    assert!(verify_qualified_delta(&pin, &p, Some(&parent), &e).is_err());
    assert!(verify_qualified_delta(&"2".repeat(64), &p, e.review.parent.as_ref(), &e).is_err());
}
proptest::proptest! {
 #[test]
 fn changed_qualification_bytes_cannot_self_approve(suffix in "[a-z]{1,16}"){
  let(p,mut e,pin)=fixture();e.delta.push_str(&suffix);proptest::prop_assert!(verify_qualified_delta(&pin,&p,e.review.parent.as_ref(),&e).is_err());
 }
}
