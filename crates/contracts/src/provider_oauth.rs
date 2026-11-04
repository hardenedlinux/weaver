// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Issuer-signed opaque access grants for the mTLS provider resource.
use crate::{Error, Result, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// Deployment-owned issuer and resource binding for one operation principal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderOAuthDeployment {
    pub issuer: String,
    pub public_key: String,
    pub subject: String,
    pub client: String,
    pub audience: String,
}

impl ProviderOAuthDeployment {
    pub fn validate(&self) -> Result<()> {
        for value in [&self.issuer, &self.subject, &self.client, &self.audience] {
            identifier(value)?;
        }
        oauth_hex(&self.public_key, 64)
    }
}

/// Claims authenticated by the independent issuer's signature over the digest.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderOAuthGrant {
    pub issuer: String,
    pub subject: String,
    pub client: String,
    pub audience: String,
    pub scopes: Vec<String>,
    pub token_hash: String,
    pub certificate_sha256: String,
    pub not_before: u64,
    pub expires_at: u64,
    pub signature: String,
}

impl ProviderOAuthGrant {
    pub fn validate(&self) -> Result<()> {
        oauth_hex(&self.token_hash, 64)?;
        oauth_hex(&self.certificate_sha256, 64)?;
        oauth_hex(&self.signature, 128)?;
        if self.scopes.is_empty()
            || self.scopes.len() > 2
            || self.scopes.windows(2).any(|pair| pair[0] >= pair[1])
            || self
                .scopes
                .iter()
                .any(|scope| !matches!(scope.as_str(), "provider:execute" | "provider:inspect"))
            || !(1..=3600).contains(&self.expires_at.saturating_sub(self.not_before))
        {
            return Err(Error::Invalid("provider OAuth grant bounds"));
        }
        Ok(())
    }

    pub fn signing_digest(&self) -> Result<String> {
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.provider-oauth.grant.v1",
            &self.issuer,
            &self.subject,
            &self.client,
            &self.audience,
            &self.scopes,
            &self.token_hash,
            &self.certificate_sha256,
            self.not_before,
            self.expires_at,
        ))?))
    }
}

/// Verify the canonical encoding for an OAuth digest or signature.
pub fn oauth_hex(value: &str, length: usize) -> Result<()> {
    if value.len() != length
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(Error::Invalid("provider OAuth digest encoding"));
    }
    Ok(())
}

/// Request observations extracted by the host from the bearer and actual TLS peer.
#[derive(Clone)]
pub struct ProviderOAuthUse {
    pub token_hash: String,
    pub certificate_sha256: String,
}
