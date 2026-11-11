// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! OIDC identity validation against issuer-controlled keys and account registrations.

use super::{
    http::OAuthHttp,
    settings::{OAuthConfiguration, OidcConfiguration, OidcSettings, OpenAiIdentitySettings},
    store::TokenStore,
};
use crate::{Endpoint, Error, Protocol};
use jsonwebtoken::{
    Algorithm, DecodingKey, Validation, decode, decode_header,
    jwk::{JwkSet, KeyAlgorithm, KeyOperations, PublicKeyUse},
};
use oauth2::CsrfToken;
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

/// Verified registration metadata for an account picker.
pub struct AccountIdentity {
    client_id: String,
    subject: String,
    email: Option<String>,
}

impl AccountIdentity {
    /// Issued client registration associated with this account.
    pub fn client_id(&self) -> &str {
        &self.client_id
    }
    /// Verified identity-provider subject.
    pub fn subject(&self) -> &str {
        &self.subject
    }
    /// Email, when returned in the verified ID token.
    pub fn email(&self) -> Option<&str> {
        self.email.as_deref()
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Registration {
    pub client_id: Option<String>,
    pub subject: Option<String>,
    pub email: Option<String>,
    pub id_token: Option<String>,
    pub nonce: Option<String>,
    pub host_id: String,
}

impl Drop for Registration {
    fn drop(&mut self) {
        self.id_token.zeroize();
        self.nonce.zeroize();
    }
}

impl Registration {
    pub fn account(&self) -> Option<AccountIdentity> {
        Some(AccountIdentity {
            client_id: self.client_id.clone()?,
            subject: self.subject.clone()?,
            email: self.email.clone(),
        })
    }

    pub fn issued_client(&self) -> &str {
        self.client_id.as_deref().unwrap_or("dynamic_agent_client")
    }

    pub fn callback_client(&self, returned: Option<&str>) -> Result<String, Error> {
        match (&self.client_id, returned) {
            (Some(expected), None) => Ok(expected.clone()),
            (Some(expected), Some(actual)) if actual == expected => Ok(expected.clone()),
            (None, Some(actual)) if valid_client_id(actual) => Ok(actual.to_owned()),
            _ => Err(Error::Authentication),
        }
    }
}

pub(super) fn valid_client_id(value: &str) -> bool {
    value != "dynamic_agent_client"
        && !value.is_empty()
        && value.len() <= 1024
        && value.bytes().all(|b| b.is_ascii_graphic())
}

pub(super) fn registered_account(
    saved: Option<Registration>,
    client: &str,
) -> Result<Registration, Error> {
    match saved {
        Some(saved)
            if saved.client_id.as_deref() == Some(client)
                && saved.host_id.is_empty()
                && saved.subject.as_deref().is_none_or(|s| !s.is_empty())
                && saved.id_token.is_some() == saved.nonce.is_some()
                && (saved.id_token.is_none() || saved.subject.is_some()) =>
        {
            Ok(saved)
        }
        Some(_) => Err(Error::Configuration),
        None => Ok(Registration {
            client_id: Some(client.to_owned()),
            subject: None,
            email: None,
            id_token: None,
            nonce: None,
            host_id: String::new(),
        }),
    }
}

pub(crate) async fn discover_oidc(
    config: OidcConfiguration,
    client: reqwest::Client,
) -> Result<OAuthConfiguration, Error> {
    if !valid_client_id(&config.client_id)
        || !config.scopes.iter().any(|s| s == "openid")
        || Endpoint::new(Protocol::OpenAi, &config.issuer)?
            .url
            .query()
            .is_some()
    {
        return Err(Error::Configuration);
    }
    let http = OAuthHttp {
        client,
        headers: reqwest::header::HeaderMap::new(),
        github_token_url: None,
    };
    let metadata = metadata(&config.issuer, &http).await?;
    let authorization = metadata
        .authorization_endpoint
        .ok_or(Error::Configuration)?;
    let token = metadata.token_endpoint.ok_or(Error::Configuration)?;
    for url in [&authorization, &token] {
        if Endpoint::new(Protocol::OpenAi, url)?.url.query().is_some() {
            return Err(Error::Configuration);
        }
    }
    Ok(OAuthConfiguration {
        client_id: config.client_id,
        token_url: token,
        authorization_url: Some(authorization),
        device_authorization_url: None,
        redirect_uri: Some(config.redirect_uri),
        resource: Some(config.resource),
        scopes: config.scopes,
        token_file: config.token_file,
        login_timeout_ms: config.login_timeout_ms,
        openai: None,
        copilot: None,
        exchange: None,
        oidc: Some(OidcSettings {
            issuer: config.issuer,
            revoke_on_logout: config.revoke_on_logout,
        }),
    })
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Host {
    id: String,
}

pub(super) async fn registration(
    config: &OpenAiIdentitySettings,
    saved: Option<Registration>,
) -> Result<Registration, Error> {
    let store = TokenStore::open(&config.host_id_file).await?;
    let host = match store.load::<Host>().await? {
        Some(host) => host,
        None => {
            let host = Host {
                id: format!("urn:uuid:{}", uuid::Uuid::new_v4()),
            };
            store.save(&host).await?;
            host
        }
    };
    let id = host
        .id
        .strip_prefix("urn:uuid:")
        .and_then(|id| uuid::Uuid::parse_str(id).ok())
        .filter(|id| id.get_version_num() == 4)
        .ok_or(Error::Configuration)?;
    if host.id != format!("urn:uuid:{id}") {
        return Err(Error::Configuration);
    }
    match saved {
        Some(saved)
            if saved.host_id == host.id
                && saved.client_id.as_deref().is_none_or(valid_client_id)
                && saved.subject.as_deref().is_none_or(|s| !s.is_empty())
                && (saved.subject.is_none() || saved.client_id.is_some())
                && (saved.id_token.is_some() == saved.nonce.is_some())
                && (saved.id_token.is_none() || saved.subject.is_some()) =>
        {
            Ok(saved)
        }
        Some(_) => Err(Error::Configuration),
        None => Ok(Registration {
            client_id: None,
            subject: None,
            email: None,
            id_token: None,
            nonce: None,
            host_id: host.id,
        }),
    }
}

#[derive(Deserialize)]
struct Metadata {
    issuer: String,
    jwks_uri: String,
    revocation_endpoint: Option<String>,
    authorization_endpoint: Option<String>,
    token_endpoint: Option<String>,
}

#[derive(Deserialize)]
struct Claims {
    sub: String,
    exp: u64,
    iat: u64,
    nonce: Option<String>,
    email: Option<String>,
    aud: Audience,
    azp: Option<String>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Audience {
    One(String),
    Many(Vec<String>),
}

pub(super) async fn verify(
    issuer: &str,
    http: &OAuthHttp,
    registration: &Registration,
    id_token: &str,
    nonce: Option<&CsrfToken>,
) -> Result<Registration, Error> {
    let client = registration
        .client_id
        .as_deref()
        .filter(|id| valid_client_id(id))
        .ok_or(Error::Authentication)?;
    let metadata = metadata(issuer, http).await?;
    let keys: JwkSet = http.get_json(&metadata.jwks_uri).await?;
    let claims = verify_signature(id_token, issuer, client, &keys)?;
    let expected_nonce = nonce.map(CsrfToken::secret).map(String::as_str);
    validate_identity(&claims, registration, expected_nonce)?;
    let mut verified = registration.clone();
    verified.subject = Some(claims.sub);
    verified.email = claims.email;
    verified.id_token = Some(id_token.to_owned());
    if let Some(nonce) = expected_nonce {
        verified.nonce = Some(nonce.to_owned());
    }
    Ok(verified)
}

fn verify_signature(
    token: &str,
    issuer: &str,
    client: &str,
    keys: &JwkSet,
) -> Result<Claims, Error> {
    let header = decode_header(token).map_err(|_| Error::Authentication)?;
    if header.alg != Algorithm::RS256 {
        return Err(Error::Authentication);
    }
    let kid = header
        .kid
        .as_deref()
        .filter(|s| !s.is_empty())
        .ok_or(Error::Authentication)?;
    let mut matching = keys
        .keys
        .iter()
        .filter(|key| key.common.key_id.as_deref() == Some(kid));
    let key = matching.next().ok_or(Error::Authentication)?;
    if matching.next().is_some()
        || key
            .common
            .key_algorithm
            .is_some_and(|alg| alg != KeyAlgorithm::RS256)
        || key
            .common
            .public_key_use
            .as_ref()
            .is_some_and(|usage| usage != &PublicKeyUse::Signature)
        || key
            .common
            .key_operations
            .as_ref()
            .is_some_and(|ops| !ops.contains(&KeyOperations::Verify))
    {
        return Err(Error::Authentication);
    }
    let key = DecodingKey::from_jwk(key).map_err(|_| Error::Authentication)?;
    let mut validation = Validation::new(Algorithm::RS256);
    validation.leeway = 0;
    validation.validate_nbf = true;
    validation.set_issuer(&[issuer]);
    validation.set_audience(&[client]);
    validation.set_required_spec_claims(&["exp", "iss", "aud", "sub"]);
    decode::<Claims>(token, &key, &validation)
        .map(|data| data.claims)
        .map_err(|_| Error::Authentication)
}

fn validate_identity(
    claims: &Claims,
    saved: &Registration,
    nonce: Option<&str>,
) -> Result<(), Error> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| Error::Authentication)?
        .as_secs();
    let expected = nonce.or(saved.nonce.as_deref());
    let nonce_valid = match (nonce, claims.nonce.as_deref(), expected) {
        (Some(_), Some(actual), Some(expected)) => {
            CsrfToken::new(actual.to_owned()) == CsrfToken::new(expected.to_owned())
        }
        (None, None, _) => true,
        (None, Some(actual), Some(expected)) => {
            CsrfToken::new(actual.to_owned()) == CsrfToken::new(expected.to_owned())
        }
        _ => false,
    };
    let client = saved.client_id.as_deref().ok_or(Error::Authentication)?;
    let audiences = match &claims.aud {
        Audience::One(value) => std::slice::from_ref(value),
        Audience::Many(values) => values.as_slice(),
    };
    if !nonce_valid
        || claims.sub.is_empty()
        || claims.iat > now
        || claims.exp <= now
        || claims.iat >= claims.exp
        || saved
            .subject
            .as_ref()
            .is_some_and(|subject| subject != &claims.sub)
        || !audiences.iter().any(|aud| aud == client)
        || (audiences.len() > 1 && claims.azp.as_deref() != Some(client))
        || claims.azp.as_deref().is_some_and(|azp| azp != client)
    {
        return Err(Error::Authentication);
    }
    Ok(())
}

async fn metadata(issuer: &str, http: &OAuthHttp) -> Result<Metadata, Error> {
    let metadata: Metadata = http
        .get_json(&format!(
            "{}/.well-known/openid-configuration",
            issuer.trim_end_matches('/')
        ))
        .await?;
    if metadata.issuer != issuer {
        return Err(Error::Authentication);
    }
    Endpoint::new(Protocol::OpenAi, &metadata.jwks_uri)?;
    if let Some(url) = &metadata.revocation_endpoint {
        Endpoint::new(Protocol::OpenAi, url)?;
    }
    Ok(metadata)
}

pub(super) async fn revoke(
    issuer: &str,
    http: &OAuthHttp,
    client: &str,
    refresh: &str,
) -> Result<(), Error> {
    let url = metadata(issuer, http)
        .await?
        .revocation_endpoint
        .ok_or(Error::Authentication)?;
    for attempt in 0..3 {
        let response = http
            .post_form(
                &url,
                &[
                    ("token", refresh),
                    ("token_type_hint", "refresh_token"),
                    ("client_id", client),
                ],
            )
            .await;
        match response {
            Ok(response) if response.status() == oauth2::http::StatusCode::OK => return Ok(()),
            Ok(response) if !response.status().is_server_error() => {
                return Err(Error::Authentication);
            }
            _ if attempt < 2 => {
                tokio::time::sleep(std::time::Duration::from_millis(100 << attempt)).await
            }
            _ => {}
        }
    }
    Err(Error::Authentication)
}

#[cfg(test)]
#[path = "../../tests/unit/openai_identity.rs"]
mod tests;
