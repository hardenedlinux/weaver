// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

#[path = "../../benches/support/source_authority.rs"]
mod fixture;
use proptest::{prop_assert_ne, proptest};
use weaver_contracts::{
    SourceAuthority, SourceRotation, SourceRotationOutcome, SourceRotationReceipt, body_digest,
};

#[test]
fn rotation_receipts_cannot_substitute_the_original_committed_binding() {
    let command = SourceRotation {
        operation_id: "handoff".into(),
        expected_epoch: 0,
        next: fixture::source_identity(1),
    };
    let mut receipt = SourceRotationReceipt {
        operation_id: command.operation_id.clone(),
        digest: command.digest().expect("digest"),
        outcome: SourceRotationOutcome::Committed,
        authority: SourceAuthority {
            epoch: 1,
            identity: command.next.clone(),
        },
    };
    receipt.validate_for(&command).expect("bound original");
    receipt.authority.identity = fixture::source_identity(2);
    assert!(receipt.validate_for(&command).is_err());
}

proptest! {
    #[test]
    fn handoff_digest_covers_each_original_field(field in 0u8..5) {
        let original=SourceRotation {operation_id:"handoff".into(),expected_epoch:0,next:fixture::source_identity(1)};
        let mut other=original.clone();
        match field {0=>other.operation_id.push('x'),1=>other.expected_epoch=1,2=>other.next.certificate_sha256=body_digest("different certificate"),3=>other.next.public_key_sha256=body_digest("different SPKI"),_=>other.next.credential_sha256=body_digest("different role credential")};
        prop_assert_ne!(original.digest().expect("original"),other.digest().expect("changed"));
    }
}
