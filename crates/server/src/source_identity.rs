// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Certificate identity is derived from DER/SPKI, never a request-supplied actor name.
use sha2::{Digest, Sha256};
use tonic::Status;
use weaver_contracts::{SourceAuthority, SourceIdentity};

/// Derive bounded certificate/SPKI fingerprints. This does not verify a CA chain,
/// prove key possession, select a source role or authorize a ledger mutation.
pub fn certificate_identity(
    der: &[u8],
    credential_sha256: String,
) -> Result<SourceIdentity, Status> {
    if der.is_empty() || der.len() > 16384 {
        return Err(Status::invalid_argument("source certificate bound"));
    }
    let certificate = rustls::pki_types::CertificateDer::from(der);
    let parsed = rustls::server::ParsedCertificate::try_from(&certificate)
        .map_err(|_| Status::invalid_argument("source certificate invalid"))?;
    let identity = SourceIdentity {
        certificate_sha256: hex::encode(Sha256::digest(der)),
        public_key_sha256: hex::encode(Sha256::digest(parsed.subject_public_key_info().as_ref())),
        credential_sha256,
    };
    identity
        .validate()
        .map_err(|_| Status::invalid_argument("source identity invalid"))?;
    Ok(identity)
}
pub(crate) fn view(authority: SourceAuthority) -> Result<crate::pb::SourceAuthorityView, Status> {
    Ok(crate::pb::SourceAuthorityView {
        epoch: authority.epoch,
        identity_digest: authority
            .identity
            .digest()
            .map_err(|_| Status::failed_precondition("source identity binding"))?,
    })
}
