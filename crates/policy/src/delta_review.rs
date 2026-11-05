// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authenticate a configured SPEC review producer; never infer NoGain from replay.
use weaver_contracts::{
    DeltaDisposition, DeltaReview, Error, Result, ReviewAuthority, SourceAuthority,
};

/// Authenticate producer evidence against the deployment and current source.
/// This verifies exact signed bindings, not semantic Delta soundness or NoGain.
pub fn verify_delta_review(
    authority: &ReviewAuthority,
    source: &SourceAuthority,
    evidence: &DeltaReview,
) -> Result<()> {
    authority.validate()?;
    evidence.validate()?;
    if authority.audience != evidence.audience
        || authority.epoch != evidence.reviewer_epoch
        || source.epoch != evidence.source_epoch
        || source.identity.digest()? != evidence.source_identity_digest
    {
        return Err(Error::Denied);
    }
    match (&evidence.review.parent, evidence.disposition) {
        (None, DeltaDisposition::Bootstrap) | (Some(_), DeltaDisposition::NoExecutionGain) => {}
        (Some(_), DeltaDisposition::ExplicitApproval) if authority.allow_expansion => {}
        _ => return Err(Error::Denied),
    }
    verify_signature(
        &authority.public_key,
        &evidence.signing_digest()?,
        &evidence.signature,
    )
}

pub(crate) fn verify_signature(key: &str, message: &str, signature: &str) -> Result<()> {
    let key = hex::decode(key).map_err(|_| Error::Denied)?;
    let message = hex::decode(message).map_err(|_| Error::Denied)?;
    let signature = hex::decode(signature).map_err(|_| Error::Denied)?;
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(&message, &signature)
        .map_err(|_| Error::Denied)
}

#[cfg(test)]
#[path = "../tests/unit/delta_review.rs"]
mod tests;
