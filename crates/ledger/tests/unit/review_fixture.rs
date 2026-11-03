// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Synthetic independent issuer, explicitly not a SPEC semantic proof producer.
use ring::signature::{Ed25519KeyPair, KeyPair};
use weaver_contracts::{
    DeltaDisposition, DeltaReview, Publication, PublicationReview, ReviewAuthority, SourceIdentity,
};
pub fn source() -> SourceIdentity {
    SourceIdentity {
        certificate_sha256: "1".repeat(64),
        public_key_sha256: "2".repeat(64),
        credential_sha256: "3".repeat(64),
    }
}
pub fn issuer(epoch: u64) -> ReviewAuthority {
    let key = Ed25519KeyPair::from_seed_unchecked(&[23; 32]).expect("test key");
    ReviewAuthority {
        audience: "test-gateway".into(),
        epoch,
        public_key: hex::encode(key.public_key().as_ref()),
        allow_expansion: false,
    }
}
pub fn change(id: &str, parent: Option<u64>) -> Publication {
    Publication {
        operation_id: id.into(),
        expected_revision: parent,
        fence: 1,
        policy: "permit(principal,action,resource);".into(),
        schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
    }
}
pub fn evidence(ledger: &mut weaver_ledger::Ledger, p: &Publication) -> DeltaReview {
    let ctx = ledger
        .with_authenticated_source(&source(), |l| {
            let key = l.stage_reviewed_authority(p)?;
            l.publication_review_context(&key)
        })
        .expect("context");
    let mut e = DeltaReview {
        review: PublicationReview {
            publication: ctx.publication,
            parent: ctx.parent,
            artifact: "controlled producer fixture".into(),
        },
        audience: ctx.reviewer.audience,
        reviewer_epoch: ctx.reviewer.epoch,
        source_epoch: ctx.source.epoch,
        source_identity_digest: ctx.source.identity.digest().expect("identity"),
        disposition: if p.expected_revision.is_none() {
            DeltaDisposition::Bootstrap
        } else {
            DeltaDisposition::NoExecutionGain
        },
        delta: "synthetic fixture; no semantic proof claim".into(),
        signature: String::new(),
    };
    let key = Ed25519KeyPair::from_seed_unchecked(&[23; 32]).expect("key");
    e.signature = hex::encode(
        key.sign(&hex::decode(e.signing_digest().expect("digest")).expect("hex"))
            .as_ref(),
    );
    e
}
