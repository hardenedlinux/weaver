// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! RFC 8693 exchange shares the identity owner and its durable uncertainty barrier.

use super::{
    credentials::{StoredToken, scope_matches, valid_access},
    exchange_types::{
        ACCESS_TOKEN, DelegatedCredential, ExchangeConfiguration, ExchangeCredentials,
        ExchangeSettings,
    },
    owner::{OAuthSession, State, now},
    settings::OAuthConfiguration,
};
use crate::{Endpoint, Error, Protocol};
use base64::Engine;
use oauth2::{TokenResponse, basic::BasicTokenType};
use serde::{Deserialize, Serialize};
use std::{path::Path, sync::Arc};
use zeroize::Zeroizing;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Extra {
    issued_token_type: String,
}
impl oauth2::ExtraTokenFields for Extra {}
type Response = oauth2::StandardTokenResponse<Extra, BasicTokenType>;

impl ExchangeConfiguration {
    pub(super) async fn prepare(
        &self,
        directory: &Path,
        resource: &str,
    ) -> Result<(ExchangeSettings, ExchangeCredentials), Error> {
        let endpoint = Endpoint::new(Protocol::OpenAi, resource)?;
        if endpoint.url.query().is_some()
            || endpoint.url.path() != "/"
            || Endpoint::new(Protocol::OpenAi, &self.token_url)?
                .url
                .query()
                .is_some()
            || self.client_id.is_empty()
            || self.client_id.len() > 1024
            || !self.client_id.bytes().all(|b| b.is_ascii_graphic())
            || self.audience.trim().is_empty()
            || self.audience.len() > 2048
            || self.scopes.is_empty()
            || self
                .scopes
                .iter()
                .any(|s| s.is_empty() || s.contains(char::is_whitespace))
        {
            return Err(Error::Configuration);
        }
        let client_secret = match &self.client_secret {
            Some(source) => Some(source.resolve(directory).await?),
            None => None,
        };
        let actor = match &self.actor {
            Some(actor) => Some(actor.token.resolve(directory).await?),
            None => None,
        };
        if let Some(actor) = &actor {
            let at = now()?;
            if !valid_access(actor)
                || self
                    .actor
                    .as_ref()
                    .is_none_or(|a| a.expires_at <= at.saturating_add(30))
            {
                return Err(Error::Configuration);
            }
        }
        use sha2::{Digest, Sha256};
        let digest =
            |secret: &Zeroizing<String>| format!("{:x}", Sha256::digest(secret.as_bytes()));
        Ok((
            ExchangeSettings {
                token_url: self.token_url.clone(),
                client_id: self.client_id.clone(),
                resource: endpoint.url.to_string(),
                audience: self.audience.clone(),
                scopes: self.scopes.clone(),
                client_secret_sha256: client_secret.as_ref().map(digest),
                actor_sha256: actor.as_ref().map(digest),
                actor_type: self.actor.as_ref().map(|a| a.token_type),
                actor_expires_at: self.actor.as_ref().map(|a| a.expires_at),
                operation_sha256: None,
            },
            ExchangeCredentials {
                client_secret,
                actor,
            },
        ))
    }
}

impl OAuthSession {
    pub(crate) async fn open_exchange(
        mut config: OAuthConfiguration,
        destination: &str,
        http: reqwest::Client,
        exchange: &ExchangeConfiguration,
        directory: &Path,
        operation_binding: Option<String>,
    ) -> Result<Self, Error> {
        let (mut settings, credentials) = exchange.prepare(directory, destination).await?;
        settings.operation_sha256 = operation_binding;
        config.exchange = Some(settings);
        let mut session = Self::open(config, destination, http).await?;
        Arc::get_mut(&mut session.0)
            .ok_or(Error::Configuration)?
            .exchange_credentials = Some(credentials);
        Ok(session)
    }

    /// Acquire an additional credential only for the configured canonical resource.
    /// No provider grant is issued and no model or RPC request is retried.
    ///
    /// # Errors
    /// Denies unbound resources, expired identity/actor credentials and unknown
    /// exchange results. A cancelled POST requires a fresh parent authorization.
    pub async fn delegated_credential(&self, resource: &str) -> Result<DelegatedCredential, Error> {
        let settings = self
            .0
            .config
            .exchange
            .as_ref()
            .ok_or(Error::Configuration)?;
        let endpoint = Endpoint::new(Protocol::OpenAi, resource)?;
        if endpoint.url.as_str() != settings.resource {
            return Err(Error::Configuration);
        }
        self.acquire_delegation(settings).await
    }

    async fn acquire_delegation(
        &self,
        settings: &ExchangeSettings,
    ) -> Result<DelegatedCredential, Error> {
        let parent = self.access_token().await?;
        let mut state = self.0.state.lock().await;
        let at = now()?;
        if self.0.store.is_closed()
            || state.record.uncertain
            || state.record.exchange_uncertain
            || !state
                .cached
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, &parent))
            || settings.actor_expires_at.is_some_and(|expiry| at >= expiry)
        {
            return Err(Error::Authentication);
        }
        let parent_expiry = state
            .record
            .token
            .as_ref()
            .ok_or(Error::Authentication)?
            .expires_at;
        if let Some(token) = state.record.delegation.as_ref().filter(|t| t.fresh(at)) {
            return Ok(DelegatedCredential {
                value: state
                    .cached_delegation
                    .clone()
                    .ok_or(Error::Authentication)?,
                expires_at: token.expires_at,
                resource: settings.resource.clone(),
            });
        }
        state.record.exchange_uncertain = true;
        state.record.delegation = None;
        state.cached_delegation = None;
        self.0.store.save(&state.record).await?;
        let started = now()?;
        let response = self.exchange(&parent).await?;
        self.commit_exchange(&mut state, &parent, response, started, parent_expiry)
            .await
    }

    async fn commit_exchange(
        &self,
        state: &mut State,
        parent: &str,
        response: Response,
        started: u64,
        parent_expiry: u64,
    ) -> Result<DelegatedCredential, Error> {
        let settings = self
            .0
            .config
            .exchange
            .as_ref()
            .ok_or(Error::Configuration)?;
        let token = validate_response(response, settings, started, parent_expiry, now()?)?;
        let credentials = self
            .0
            .exchange_credentials
            .as_ref()
            .ok_or(Error::Configuration)?;
        if [&credentials.actor, &credentials.client_secret]
            .into_iter()
            .flatten()
            .any(|value| {
                oauth2::AccessToken::new(token.access.clone())
                    == oauth2::AccessToken::new(value.to_string())
            })
        {
            return Err(Error::Authentication);
        }
        if oauth2::AccessToken::new(token.access.clone())
            == oauth2::AccessToken::new(parent.to_string())
        {
            return Err(Error::Authentication);
        }
        let mut candidate = state.record.clone();
        candidate.exchange_uncertain = false;
        candidate.delegation = Some(token);
        self.0.store.save(&candidate).await?;
        let token = candidate.delegation.as_ref().ok_or(Error::Authentication)?;
        let value = Arc::new(Zeroizing::new(token.access.clone()));
        let credential = DelegatedCredential {
            value: value.clone(),
            expires_at: token.expires_at,
            resource: settings.resource.clone(),
        };
        state.record = candidate;
        state.cached_delegation = Some(value);
        Ok(credential)
    }

    async fn exchange(&self, parent: &str) -> Result<Response, Error> {
        let config = self
            .0
            .config
            .exchange
            .as_ref()
            .ok_or(Error::Configuration)?;
        let credentials = self
            .0
            .exchange_credentials
            .as_ref()
            .ok_or(Error::Configuration)?;
        let scope = config.scopes.join(" ");
        let mut form = vec![
            (
                "grant_type",
                "urn:ietf:params:oauth:grant-type:token-exchange",
            ),
            ("subject_token", parent),
            ("subject_token_type", ACCESS_TOKEN),
            ("requested_token_type", ACCESS_TOKEN),
            ("resource", config.resource.as_str()),
            ("audience", config.audience.as_str()),
            ("scope", scope.as_str()),
        ];
        if let Some(actor) = &credentials.actor {
            form.push(("actor_token", actor.as_str()));
            form.push((
                "actor_token_type",
                config.actor_type.ok_or(Error::Configuration)?.as_str(),
            ));
        }
        let mut request = oauth2::http::Request::builder()
            .method("POST")
            .uri(&config.token_url)
            .header("accept", "application/json")
            .header("content-type", "application/x-www-form-urlencoded");
        if let Some(secret) = &credentials.client_secret {
            let encode = |s: &str| {
                oauth2::url::form_urlencoded::byte_serialize(s.as_bytes()).collect::<String>()
            };
            let basic = base64::engine::general_purpose::STANDARD.encode(format!(
                "{}:{}",
                encode(&config.client_id),
                encode(secret)
            ));
            let mut header = oauth2::http::HeaderValue::from_str(&format!("Basic {basic}"))
                .map_err(|_| Error::Authentication)?;
            header.set_sensitive(true);
            request = request.header("authorization", header);
        } else {
            form.push(("client_id", &config.client_id));
        }
        let body = oauth2::url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs(form)
            .finish()
            .into_bytes();
        let response = self
            .0
            .http
            .request(request.body(body).map_err(|_| Error::Authentication)?)
            .await?;
        if response.status() != oauth2::http::StatusCode::OK {
            return Err(Error::Authentication);
        }
        serde_json::from_slice(response.body()).map_err(|_| Error::Authentication)
    }
}

fn validate_response(
    response: Response,
    config: &ExchangeSettings,
    started: u64,
    parent_expiry: u64,
    at: u64,
) -> Result<StoredToken, Error> {
    if response.extra_fields().issued_token_type != ACCESS_TOKEN
        || response.token_type() != &BasicTokenType::Bearer
        || response.refresh_token().is_some()
    {
        return Err(Error::Authentication);
    }
    let lifetime = response
        .expires_in()
        .ok_or(Error::Authentication)?
        .as_secs();
    let expires_at = started
        .checked_add(lifetime)
        .ok_or(Error::Authentication)?
        .min(parent_expiry)
        .min(config.actor_expires_at.unwrap_or(u64::MAX));
    let scopes = response
        .scopes()
        .map(|s| s.iter().map(|s| s.to_string()).collect())
        .unwrap_or_else(|| config.scopes.clone());
    if !scope_matches(&config.scopes, &scopes) {
        return Err(Error::Authentication);
    }
    let token = StoredToken {
        access: response.access_token().secret().clone(),
        refresh: None,
        issued_at: started,
        expires_at,
        scopes,
        refresh_at: None,
    };
    if !token.valid(&config.scopes) || !token.fresh(at) {
        return Err(Error::Authentication);
    }
    Ok(token)
}

#[cfg(test)]
#[path = "../../tests/unit/exchange.rs"]
mod tests;
