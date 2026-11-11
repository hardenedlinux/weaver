// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Trusted token-exchange settings and redacted, destination-bound bearer handles.

use crate::{Error, files::SecretReference};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use zeroize::Zeroizing;

pub(super) const ACCESS_TOKEN: &str = "urn:ietf:params:oauth:token-type:access_token";

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExchangeConfiguration {
    pub token_url: String,
    pub client_id: String,
    pub audience: String,
    pub scopes: Vec<String>,
    pub client_secret: Option<SecretReference>,
    pub actor: Option<ActorConfiguration>,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ActorConfiguration {
    pub token: SecretReference,
    pub token_type: ActorTokenType,
    pub expires_at: u64,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
pub(crate) enum ActorTokenType {
    #[serde(rename = "urn:ietf:params:oauth:token-type:access_token")]
    Access,
    #[serde(rename = "urn:ietf:params:oauth:token-type:jwt")]
    Jwt,
    #[serde(rename = "urn:ietf:params:oauth:token-type:id_token")]
    Identity,
}

impl ActorTokenType {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Access => ACCESS_TOKEN,
            Self::Jwt => "urn:ietf:params:oauth:token-type:jwt",
            Self::Identity => "urn:ietf:params:oauth:token-type:id_token",
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ExchangeSettings {
    pub token_url: String,
    pub client_id: String,
    pub resource: String,
    pub audience: String,
    pub scopes: Vec<String>,
    pub client_secret_sha256: Option<String>,
    pub actor_sha256: Option<String>,
    pub actor_type: Option<ActorTokenType>,
    pub actor_expires_at: Option<u64>,
    pub operation_sha256: Option<String>,
}

pub(super) struct ExchangeCredentials {
    pub client_secret: Option<Zeroizing<String>>,
    pub actor: Option<Zeroizing<String>>,
}

/// One exchanged credential, bound by the prepared profile to a resource.
/// It is additional authority, never a replacement operation credential.
pub struct DelegatedCredential {
    pub(super) value: Arc<Zeroizing<String>>,
    pub(super) expires_at: u64,
    pub(super) resource: String,
}

impl std::fmt::Debug for DelegatedCredential {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DelegatedCredential")
            .finish_non_exhaustive()
    }
}

impl DelegatedCredential {
    /// Canonical resource URI bound by the trusted profile.
    pub fn resource(&self) -> &str {
        &self.resource
    }
    /// Upper bound, clipped to the subject and configured actor lifetimes.
    pub fn expires_at(&self) -> u64 {
        self.expires_at
    }
    /// A sensitive Bearer header for the bound resource's delegated channel.
    ///
    /// # Errors
    /// Rejects malformed token material without disclosing it.
    pub fn bearer_header(&self) -> Result<reqwest::header::HeaderValue, Error> {
        let mut value =
            reqwest::header::HeaderValue::from_str(&format!("Bearer {}", self.value.as_str()))
                .map_err(|_| Error::Authentication)?;
        value.set_sensitive(true);
        Ok(value)
    }
    /// Digest for matching an independently approved grant; this issues no grant.
    pub fn token_sha256(&self) -> String {
        use sha2::{Digest, Sha256};
        format!("{:x}", Sha256::digest(self.value.as_bytes()))
    }
}
