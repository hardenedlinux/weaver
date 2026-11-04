// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Project a second credential from the authenticated operation transport.
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use tonic::{
    Request, Status,
    transport::server::{TcpConnectInfo, TlsConnectInfo},
};
use weaver_contracts::ProviderOAuthUse;

pub(crate) fn change(
    ledger: &mut weaver_ledger::Ledger,
    action: crate::pb::provider_o_auth_change::Action,
) -> weaver_contracts::Result<()> {
    use crate::pb::provider_o_auth_change::Action;
    match action {
        Action::Grant(grant) => {
            ledger.publish_provider_oauth(&weaver_contracts::ProviderOAuthGrant {
                issuer: grant.issuer,
                subject: grant.subject,
                client: grant.client,
                audience: grant.audience,
                scopes: grant.scopes,
                token_hash: grant.token_hash,
                certificate_sha256: grant.certificate_sha256,
                not_before: grant.not_before,
                expires_at: grant.expires_at,
                signature: grant.signature,
            })
        }
        Action::RevokeTokenHash(hash) => ledger.revoke_provider_oauth(&hash),
    }
}

pub(crate) fn observe<T>(
    enabled: bool,
    request: &Request<T>,
) -> Result<Option<ProviderOAuthUse>, Status> {
    if !enabled {
        return Ok(None);
    }
    let metadata = request.metadata();
    if metadata.get_all("weaver-provider-oauth").iter().count() != 1 {
        return Err(Status::unauthenticated(
            "delegated provider credential required",
        ));
    }
    let token = metadata
        .get("weaver-provider-oauth")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|value| {
            (32..=256).contains(&value.len()) && value.bytes().all(|byte| byte.is_ascii_graphic())
        })
        .ok_or(Status::unauthenticated(
            "invalid delegated provider credential",
        ))?;
    let operation = metadata
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .ok_or(Status::unauthenticated("operation credential required"))?;
    let hash = Sha256::digest(token.as_bytes());
    if bool::from(
        hash.as_slice()
            .ct_eq(Sha256::digest(operation.as_bytes()).as_slice()),
    ) {
        return Err(Status::unauthenticated(
            "delegated and operation credentials must differ",
        ));
    }
    let peer = request
        .extensions()
        .get::<TlsConnectInfo<TcpConnectInfo>>()
        .and_then(|tls| tls.peer_certs())
        .and_then(|certs| certs.first().map(|cert| Sha256::digest(cert.as_ref())))
        .ok_or(Status::unauthenticated(
            "provider OAuth certificate missing",
        ))?;
    Ok(Some(ProviderOAuthUse {
        token_hash: hex::encode(hash),
        certificate_sha256: hex::encode(peer),
    }))
}
