// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Crypto boundary only: this fixture is not a SPEC Delta proof producer.
use proptest::{prop_assert, proptest};
use ring::signature::{Ed25519KeyPair, KeyPair};
use weaver_contracts::{
    DeltaDisposition, DeltaReview, PublicationKey, PublicationReview, ReviewAuthority,
    SourceAuthority, SourceIdentity,
};

fn fixture() -> (ReviewAuthority, SourceAuthority, DeltaReview) {
    let key = Ed25519KeyPair::from_seed_unchecked(&[23; 32]).expect("test key");
    let issuer = ReviewAuthority {
        audience: "test-gateway".into(),
        epoch: 0,
        public_key: hex::encode(key.public_key().as_ref()),
        allow_expansion: false,
        qualified_catalog: None,
    };
    let source = SourceAuthority {
        epoch: 0,
        identity: SourceIdentity {
            certificate_sha256: "1".repeat(64),
            public_key_sha256: "2".repeat(64),
            credential_sha256: "3".repeat(64),
        },
    };
    let mut evidence = DeltaReview {
        review: PublicationReview {
            publication: PublicationKey {
                operation_id: "original".into(),
                digest: "4".repeat(64),
            },
            parent: None,
            artifact: "replay bytes".into(),
        },
        audience: issuer.audience.clone(),
        reviewer_epoch: 0,
        source_epoch: 0,
        source_identity_digest: source.identity.digest().expect("identity"),
        disposition: DeltaDisposition::Bootstrap,
        delta: "opaque external review evidence".into(),
        signature: String::new(),
    };
    sign(&key, &mut evidence);
    (issuer, source, evidence)
}
fn sign(key: &Ed25519KeyPair, evidence: &mut DeltaReview) {
    evidence.signature = hex::encode(
        key.sign(&hex::decode(evidence.signing_digest().expect("binding")).expect("hex"))
            .as_ref(),
    );
}

#[test]
fn authenticated_bootstrap_requires_exact_independent_issuer() {
    let (issuer, source, evidence) = fixture();
    assert_eq!(
        evidence.signing_digest().expect("binding"),
        "632ac5780990746b2b485011cc9bcc05d6b34d83b2d22709a8339e5a8fea7351"
    );
    assert_eq!(
        evidence.signature,
        "f35db4b4a9cb1a1d7fdc095af873e3286fa3dee1749d4fe5ecb84f5aaee6d655e77f6f20a650d6946171f69cc9bc83efe5fcac7c0b3f2db27689179eba964807"
    );

    super::verify_delta_review(&issuer, &source, &evidence).expect("authenticated envelope");
    let mut wrong = issuer.clone();
    wrong.public_key = "0".repeat(64);
    assert!(super::verify_delta_review(&wrong, &source, &evidence).is_err());
}

proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(128))]
    #[test]
    fn replaying_or_relabeling_signed_review_never_supplies_new_authority(field in 0u8..12) {
        let (mut issuer,mut source,mut evidence)=fixture();
        match field {
            0=>evidence.audience="other-gateway".into(),
            1=>issuer.epoch+=1,
            2=>source.epoch+=1,
            3=>source.identity.credential_sha256="5".repeat(64),
            4=>evidence.review.publication.operation_id="renamed".into(),
            5=>evidence.review.publication.digest="6".repeat(64),
            6=>evidence.review.artifact.push(' '),
            7=>evidence.delta.push(' '),
            8=>evidence.source_epoch+=1,
            9=>evidence.disposition=DeltaDisposition::ExplicitApproval,
            10=>evidence.signature="0".repeat(128),
            _=>issuer.audience="other-instance".into(),
        }
        prop_assert!(super::verify_delta_review(&issuer,&source,&evidence).is_err());
    }
}

#[test]
fn authentic_gain_approval_is_not_enabled_by_a_reviewer_claim_alone() {
    let (mut issuer, source, mut evidence) = fixture();
    evidence.review.parent = Some(weaver_contracts::AuthorityParent {
        revision: 0,
        fence: 1,
        policy_digest: "7".repeat(64),
        schema_digest: Some("8".repeat(64)),
    });
    evidence.disposition = DeltaDisposition::ExplicitApproval;
    let key = Ed25519KeyPair::from_seed_unchecked(&[23; 32]).expect("test key");
    sign(&key, &mut evidence);
    assert!(super::verify_delta_review(&issuer, &source, &evidence).is_err());
    issuer.allow_expansion = true;
    super::verify_delta_review(&issuer, &source, &evidence)
        .expect("explicit deployment permission");
    evidence.disposition = DeltaDisposition::NoExecutionGain;
    sign(&key, &mut evidence);
    issuer.allow_expansion = false;
    super::verify_delta_review(&issuer, &source, &evidence)
        .expect("authenticated producer claim only");
}
