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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub relay_certificate_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub witness_file: Option<String>,
    pub subject: String,
    pub client: String,
    pub audience: String,
}

impl ProviderOAuthDeployment {
    pub fn validate(&self) -> Result<()> {
        for value in [&self.issuer, &self.subject, &self.client, &self.audience] {
            identifier(value)?;
        }
        oauth_hex(&self.public_key, 64)?;
        if let Some(peer) = &self.relay_certificate_sha256 {
            oauth_hex(peer, 64)?;
        }
        if self.relay_certificate_sha256.is_some() && self.witness_file.is_none() {
            return Err(Error::Invalid(
                "OAuth relay requires an independent witness",
            ));
        }
        if let Some(path) = &self.witness_file
            && (path.len() > 4096 || !std::path::Path::new(path).is_absolute())
        {
            return Err(Error::Invalid("OAuth witness path"));
        }
        Ok(())
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent_token_hash: Option<String>,
    #[serde(default, skip_serializing_if = "zero_epoch")]
    pub issuer_epoch: u64,
}

impl ProviderOAuthGrant {
    pub fn validate(&self) -> Result<()> {
        oauth_hex(&self.token_hash, 64)?;
        oauth_hex(&self.certificate_sha256, 64)?;
        oauth_hex(&self.signature, 128)?;
        if let Some(parent) = &self.parent_token_hash {
            oauth_hex(parent, 64)?;
            if parent == &self.token_hash {
                return Err(Error::Invalid("provider OAuth parent is self"));
            }
        }
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
        if self.issuer_epoch != 0 {
            return Ok(body_digest(&serde_json::to_string(&(
                "weaver.provider-oauth.epoch-grant.v1",
                &self.issuer,
                &self.subject,
                &self.client,
                &self.audience,
                &self.scopes,
                &self.token_hash,
                &self.certificate_sha256,
                self.not_before,
                self.expires_at,
                &self.parent_token_hash,
                self.issuer_epoch,
            ))?));
        }
        if let Some(parent) = &self.parent_token_hash {
            return Ok(body_digest(&serde_json::to_string(&(
                "weaver.provider-oauth.delegated-grant.v1",
                &self.issuer,
                &self.subject,
                &self.client,
                &self.audience,
                &self.scopes,
                &self.token_hash,
                &self.certificate_sha256,
                self.not_before,
                self.expires_at,
                parent,
            ))?));
        }
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

fn zero_epoch(epoch: &u64) -> bool {
    *epoch == 0
}

/// Current-issuer authorization for the next monotonic signing epoch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderOAuthIssuerRotation {
    pub expected_epoch: u64,
    pub public_key: String,
    pub signature: String,
}

impl ProviderOAuthIssuerRotation {
    pub fn signing_digest(&self, issuer: &str, current_key: &str) -> Result<String> {
        oauth_hex(&self.public_key, 64)?;
        oauth_hex(&self.signature, 128)?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.provider-oauth.rotate-issuer.v1",
            issuer,
            current_key,
            self.expected_epoch,
            &self.public_key,
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
    pub ingress_certificate_sha256: Option<String>,
}
