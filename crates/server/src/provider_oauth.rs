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
                issuer_epoch: grant.issuer_epoch,
                parent_token_hash: (!grant.parent_token_hash.is_empty())
                    .then_some(grant.parent_token_hash),
            })
        }
        Action::RevokeTokenHash(hash) => ledger.revoke_provider_oauth(&hash),
        Action::RotateIssuer(command) => {
            ledger.rotate_provider_oauth_issuer(&weaver_contracts::ProviderOAuthIssuerRotation {
                expected_epoch: command.expected_epoch,
                public_key: command.public_key,
                signature: command.signature,
            })
        }
    }
}

pub(crate) fn observe<T>(
    enabled: bool,
    relay: bool,
    request: &Request<T>,
) -> Result<Option<ProviderOAuthUse>, Status> {
    let metadata = request.metadata();
    if !enabled {
        if metadata.contains_key("weaver-provider-oauth")
            || metadata.contains_key("weaver-provider-oauth-ingress-cert")
        {
            return Err(Status::failed_precondition(
                "delegated provider OAuth is disabled",
            ));
        }
        return Ok(None);
    }
    if !relay && metadata.contains_key("weaver-provider-oauth-ingress-cert") {
        return Err(Status::unauthenticated(
            "direct ingress cannot supply relay evidence",
        ));
    }
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
    let ingress = metadata.get_all("weaver-provider-oauth-ingress-cert");
    let mut values = ingress.iter();
    let ingress_certificate_sha256 = values
        .next()
        .map(|value| {
            let value = value
                .to_str()
                .map_err(|_| Status::unauthenticated("invalid OAuth ingress evidence"))?;
            weaver_contracts::oauth_hex(value, 64)
                .map_err(|_| Status::unauthenticated("invalid OAuth ingress evidence"))?;
            Ok::<_, Status>(value.to_owned())
        })
        .transpose()?;
    if values.next().is_some() {
        return Err(Status::unauthenticated("ambiguous OAuth ingress evidence"));
    }
    Ok(Some(ProviderOAuthUse {
        token_hash: hex::encode(hash),
        certificate_sha256: hex::encode(peer),
        ingress_certificate_sha256,
    }))
}

#[cfg(test)]
#[path = "../tests/unit/provider_oauth_ingress.rs"]
mod direct_ingress_tests;
