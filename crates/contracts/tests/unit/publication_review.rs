// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use proptest::{prop_assert_ne, proptest};
use weaver_contracts::{AuthorityParent, PublicationKey, PublicationReview, body_digest, decode};

fn fixture(artifact: String) -> PublicationReview {
    PublicationReview {
        publication: PublicationKey {
            operation_id: "original".into(),
            digest: body_digest("original command"),
        },
        parent: Some(AuthorityParent {
            revision: 0,
            fence: 1,
            policy_digest: body_digest("parent Policy"),
            schema_digest: Some(body_digest("parent schema")),
        }),
        artifact,
    }
}

#[test]
fn sealed_review_bounds_and_escaped_artifact_roundtrip() {
    let largest = fixture("\0".repeat(65536));
    largest.validate().expect("bounded artifact");
    assert_eq!(
        decode::<PublicationReview>(&serde_json::to_vec(&largest).expect("encoding"))
            .expect("decoding"),
        largest
    );
    assert!(fixture(String::new()).validate().is_err());
    assert!(fixture("x".repeat(65537)).validate().is_err());
    let mut encoded =
        serde_json::to_value(fixture("approved upstream bytes".into())).expect("object");
    encoded["approved"] = true.into();
    assert!(decode::<PublicationReview>(&serde_json::to_vec(&encoded).expect("encode")).is_err());
}

proptest! {
    #[test]
    fn every_review_binding_is_part_of_the_commitment(artifact in "[a-zA-Z0-9]{1,512}",field in 0u8..7) {
        let original=fixture(artifact);let mut changed=original.clone();
        match field {
            0=>changed.artifact.push('!'),
            1=>changed.publication.operation_id.push('x'),
            2=>changed.publication.digest=body_digest("different command"),
            3=>changed.parent.as_mut().expect("parent").revision=1,
            4=>changed.parent.as_mut().expect("parent").fence=2,
            5=>changed.parent.as_mut().expect("parent").policy_digest=body_digest("different parent Policy"),
            _=>changed.parent.as_mut().expect("parent").schema_digest=None,
        }
        prop_assert_ne!(original.digest().expect("original"),changed.digest().expect("changed"));
    }
}
