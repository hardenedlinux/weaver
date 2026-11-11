// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded OAuth resource authorization and a single-owner credential lifecycle.
//! OpenAI registrations activate only after supplier identity verification.

use super::settings::OAuthConfiguration;
use super::store::TokenStore;
use super::{
    copilot::{self, ParentCredential},
    credentials::{StoredToken, scope_matches, valid_access},
    exchange_types::ExchangeCredentials,
    http::OAuthHttp,
    identity::{self, AccountIdentity, Registration},
};
use crate::{Endpoint, Error, Protocol};
use oauth2::{
    AuthType, AuthUrl, ClientId, CsrfToken, DeviceAuthorizationUrl, EndpointMaybeSet,
    EndpointNotSet, EndpointSet, RedirectUrl, RefreshToken, TokenResponse, TokenUrl,
    basic::{
        BasicErrorResponse, BasicRevocationErrorResponse, BasicTokenIntrospectionResponse,
        BasicTokenType,
    },
};
use serde::{Deserialize, Serialize};
use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::Mutex;
use zeroize::{Zeroize, Zeroizing};

pub(super) type ProtocolResponse = oauth2::StandardTokenResponse<ProtocolExtra, BasicTokenType>;
pub(super) type ProtocolClient = oauth2::Client<
    BasicErrorResponse,
    ProtocolResponse,
    BasicTokenIntrospectionResponse,
    oauth2::StandardRevocableToken,
    BasicRevocationErrorResponse,
    EndpointMaybeSet,
    EndpointMaybeSet,
    EndpointNotSet,
    EndpointNotSet,
    EndpointSet,
>;

#[derive(Clone, Deserialize, Serialize)]
pub(super) struct ProtocolExtra {
    id_token: Option<String>,
    refresh_token_expires_in: Option<u64>,
}
impl oauth2::ExtraTokenFields for ProtocolExtra {}
impl std::fmt::Debug for ProtocolExtra {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProtocolExtra").finish_non_exhaustive()
    }
}
impl Drop for ProtocolExtra {
    fn drop(&mut self) {
        self.id_token.zeroize();
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Record {
    version: u8,
    binding: String,
    pub(super) generation: u64,
    pub(super) uncertain: bool,
    pub(super) token: Option<StoredToken>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) registration: Option<Registration>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    copilot_parent: Option<ParentCredential>,
    #[serde(default)]
    pub(super) exchange_uncertain: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) delegation: Option<StoredToken>,
}

pub(super) struct State {
    pub(super) record: Record,
    pub(super) cached: Option<Arc<Zeroizing<String>>>,
    pub(super) cached_delegation: Option<Arc<Zeroizing<String>>>,
}

pub(super) struct Owner {
    pub(super) config: OAuthConfiguration,
    pub(super) client: ProtocolClient,
    pub(super) http: OAuthHttp,
    pub(super) store: TokenStore,
    pub(super) exchange_credentials: Option<ExchangeCredentials>,
    pub(super) state: Mutex<State>,
}

/// Clones share one refresh gate and one exclusively owned private token store.
#[derive(Clone)]
pub struct OAuthSession(pub(super) Arc<Owner>);

impl std::fmt::Debug for OAuthSession {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OAuthSession").finish_non_exhaustive()
    }
}

impl OAuthSession {
    pub(crate) async fn open(
        config: OAuthConfiguration,
        destination: &str,
        http: reqwest::Client,
    ) -> Result<Self, Error> {
        if config.client_id.trim().is_empty()
            || config.login_timeout_ms == 0
            || config.scopes.is_empty()
            || config.scopes.iter().any(|s| {
                s.is_empty()
                    || s.contains(char::is_whitespace)
                    || (s == "openid" && config.openai.is_none() && config.oidc.is_none())
            })
        {
            return Err(Error::Configuration);
        }
        for url in [&config.token_url]
            .into_iter()
            .chain(config.authorization_url.iter())
            .chain(config.device_authorization_url.iter())
            .chain(config.redirect_uri.iter())
        {
            if Endpoint::new(Protocol::OpenAi, url)?.url.query().is_some() {
                return Err(Error::Configuration);
            }
        }
        if config.oidc.is_some()
            && (config.openai.is_some()
                || config.copilot.is_some()
                || !identity::valid_client_id(&config.client_id)
                || !config.scopes.iter().any(|s| s == "openid"))
        {
            return Err(Error::Configuration);
        }
        if config.exchange.is_some() && config.oidc.is_none() {
            return Err(Error::Configuration);
        }
        let client = protocol_client(&config, &config.client_id)?;
        if let Some(openai) = &config.openai {
            if openai.agent_name.trim().is_empty() || config.client_id != "dynamic_agent_client" {
                return Err(Error::Configuration);
            }
            Endpoint::new(Protocol::OpenAi, &openai.issuer)?;
        }
        if let Some(copilot) = &config.copilot {
            if config.openai.is_some()
                || config.oidc.is_some()
                || config.authorization_url.is_some()
            {
                return Err(Error::Configuration);
            }
            if Endpoint::new(Protocol::OpenAi, &copilot.api_token_url)?
                .url
                .query()
                .is_some()
            {
                return Err(Error::Configuration);
            }
        }
        use sha2::{Digest, Sha256};
        let binding = format!(
            "{:x}",
            Sha256::digest(
                serde_json::to_vec(&(&config, destination)).map_err(|_| Error::Configuration)?
            )
        );
        let store = TokenStore::open(&config.token_file).await?;
        let mut record = store.load().await?.unwrap_or(Record {
            version: 1,
            binding: binding.clone(),
            generation: 0,
            uncertain: false,
            token: None,
            registration: None,
            copilot_parent: None,
            exchange_uncertain: false,
            delegation: None,
        });
        if record.version != 1
            || record.binding != binding
            || (record.uncertain && record.token.is_some())
            || record
                .token
                .as_ref()
                .is_some_and(|t| !t.valid(&config.scopes))
            || (config.openai.is_none() && config.oidc.is_none() && record.registration.is_some())
            || (config.copilot.is_none() && record.copilot_parent.is_some())
            || (record.uncertain && record.copilot_parent.is_some())
            || record
                .copilot_parent
                .as_ref()
                .is_some_and(|p| !p.well_formed())
            || (config.copilot.is_some()
                && record.token.is_some()
                && record.copilot_parent.is_none())
        {
            return Err(Error::Configuration);
        }
        match &config.exchange {
            None if record.delegation.is_some() || record.exchange_uncertain => {
                return Err(Error::Configuration);
            }
            Some(exchange)
                if record.delegation.as_ref().is_some_and(|child| {
                    record.uncertain
                        || record.exchange_uncertain
                        || !child.valid(&exchange.scopes)
                        || child.refresh.is_some()
                        || record.token.as_ref().is_none_or(|parent| {
                            child.expires_at > parent.expires_at
                                || child.issued_at < parent.issued_at
                        })
                }) =>
            {
                return Err(Error::Configuration);
            }
            Some(_) | None => {}
        }
        if let Some(openai) = &config.openai {
            record.registration =
                Some(identity::registration(openai, record.registration.take()).await?);
        } else if config.oidc.is_some() {
            record.registration = Some(identity::registered_account(
                record.registration.take(),
                &config.client_id,
            )?);
        }
        if (config.openai.is_some() || config.oidc.is_some()) && record.token.is_some() {
            let registration = record.registration.as_ref().ok_or(Error::Configuration)?;
            if registration.account().is_none()
                || registration.id_token.is_none()
                || registration.nonce.is_none()
                || (config.openai.is_some()
                    && record.token.as_ref().is_some_and(|t| t.refresh.is_none()))
            {
                return Err(Error::Configuration);
            }
        }
        let cached = record
            .token
            .as_ref()
            .filter(|_| !record.uncertain)
            .map(|t| Arc::new(Zeroizing::new(t.access.clone())));
        let cached_delegation = record
            .delegation
            .as_ref()
            .map(|t| Arc::new(Zeroizing::new(t.access.clone())));
        let headers = if config.copilot.is_some() {
            copilot::headers()
        } else {
            reqwest::header::HeaderMap::new()
        };
        let github_token_url = config.copilot.as_ref().map(|_| config.token_url.clone());
        Ok(Self(Arc::new(Owner {
            config,
            client,
            http: OAuthHttp {
                client: http,
                headers,
                github_token_url,
            },
            store,
            exchange_credentials: None,
            state: Mutex::new(State {
                record,
                cached,
                cached_delegation,
            }),
        })))
    }

    pub(super) fn protocol_client(
        &self,
        registration: Option<&Registration>,
    ) -> Result<ProtocolClient, Error> {
        match registration {
            Some(registration) => protocol_client(&self.0.config, registration.issued_client()),
            None => Ok(self.0.client.clone()),
        }
    }

    pub(super) fn identity_issuer(&self) -> Option<&str> {
        self.0
            .config
            .openai
            .as_ref()
            .map(|c| c.issuer.as_str())
            .or_else(|| self.0.config.oidc.as_ref().map(|c| c.issuer.as_str()))
    }

    fn revocation_issuer(&self) -> Option<&str> {
        self.0
            .config
            .openai
            .as_ref()
            .map(|c| c.issuer.as_str())
            .or_else(|| {
                self.0
                    .config
                    .oidc
                    .as_ref()
                    .filter(|c| c.revoke_on_logout)
                    .map(|c| c.issuer.as_str())
            })
    }

    /// Verified account metadata retained for this registration.
    pub async fn account_identity(&self) -> Option<AccountIdentity> {
        self.0
            .state
            .lock()
            .await
            .record
            .registration
            .as_ref()
            .and_then(Registration::account)
    }

    pub(crate) async fn access_token(&self) -> Result<Arc<Zeroizing<String>>, Error> {
        if self.0.store.is_closed() {
            return Err(Error::Authentication);
        }
        let mut state = self.0.state.lock().await;
        if state.record.uncertain {
            return Err(Error::Authentication);
        }
        if self.0.config.copilot.is_some() {
            let parent = state
                .record
                .copilot_parent
                .as_ref()
                .ok_or(Error::Authentication)?;
            if parent.valid(now()?) {
                return self.copilot_access(&mut state).await;
            }
            let refresh = parent
                .refresh_token(now()?)
                .ok_or(Error::Authentication)?
                .to_owned();
            return self.refresh_access(&mut state, refresh).await;
        }
        let token = state.record.token.as_ref().ok_or(Error::Authentication)?;
        if token.fresh(now()?) {
            return state.cached.clone().ok_or(Error::Authentication);
        }
        let refresh = token.refresh.as_ref().ok_or(Error::Authentication)?.clone();
        self.refresh_access(&mut state, refresh).await
    }

    async fn refresh_access(
        &self,
        state: &mut State,
        refresh: String,
    ) -> Result<Arc<Zeroizing<String>>, Error> {
        let parent_refresh_expiry = state
            .record
            .copilot_parent
            .as_ref()
            .and_then(|p| p.refresh_expires_at);
        let generation = state.record.generation;
        let client = self.protocol_client(state.record.registration.as_ref())?;
        self.pending(state).await?;
        let refresh = RefreshToken::new(refresh);
        let mut request = client.exchange_refresh_token(&refresh);
        if let Some(resource) = &self.0.config.resource {
            request = request.add_extra_param("resource", resource);
        }
        let response = request
            .request_async(&self.0.http)
            .await
            .map_err(|_| Error::Authentication)?;
        self.activate(
            state,
            generation,
            response,
            Some((refresh.secret(), parent_refresh_expiry)),
            None,
        )
        .await
    }

    pub(super) async fn pending(&self, state: &mut State) -> Result<(), Error> {
        state.cached = None;
        state.record.token = None;
        state.record.copilot_parent = None;
        state.record.delegation = None;
        state.record.exchange_uncertain = false;
        state.cached_delegation = None;
        state.record.uncertain = true;
        self.0.store.save(&state.record).await
    }

    async fn activate_copilot(
        &self,
        state: &mut State,
        response: ProtocolResponse,
        previous_refresh: Option<(&str, Option<u64>)>,
    ) -> Result<Arc<Zeroizing<String>>, Error> {
        let scopes: Vec<_> = match response.scopes() {
            Some(scopes) => scopes.iter().map(|s| s.to_string()).collect(),
            None if previous_refresh.is_some() => self.0.config.scopes.clone(),
            None => return Err(Error::Authentication),
        };
        if !scope_matches(&self.0.config.scopes, &scopes) {
            return Err(Error::Authentication);
        }
        let issued_at = now()?;
        let expires_at = response
            .expires_in()
            .map(|d| {
                issued_at
                    .checked_add(d.as_secs())
                    .ok_or(Error::Authentication)
            })
            .transpose()?;
        let parent = ParentCredential {
            access: response.access_token().secret().clone(),
            issued_at,
            expires_at,
            refresh: response
                .refresh_token()
                .map(|v| v.secret().clone())
                .or_else(|| previous_refresh.map(|(value, _)| value.to_owned())),
            refresh_expires_at: response
                .extra_fields()
                .refresh_token_expires_in
                .map(|secs| issued_at.checked_add(secs).ok_or(Error::Authentication))
                .transpose()?
                .or_else(|| previous_refresh.and_then(|(_, at)| at)),
        };
        if !parent.well_formed() || !parent.valid(issued_at) {
            return Err(Error::Authentication);
        }
        let candidate = Record {
            version: 1,
            binding: state.record.binding.clone(),
            generation: state.record.generation,
            uncertain: false,
            token: None,
            registration: None,
            copilot_parent: Some(parent),
            exchange_uncertain: false,
            delegation: None,
        };
        // The device grant has completed. Its reusable parent is durable before
        // the non-consuming GET; cancellation cannot replay the device code.
        self.0.store.save(&candidate).await?;
        state.record = candidate;
        state.cached_delegation = None;
        self.copilot_access(state).await
    }

    async fn copilot_access(&self, state: &mut State) -> Result<Arc<Zeroizing<String>>, Error> {
        let config = self
            .0
            .config
            .copilot
            .as_ref()
            .ok_or(Error::Authentication)?;
        let issued_at = now()?;
        let parent = state
            .record
            .copilot_parent
            .as_ref()
            .ok_or(Error::Authentication)?;
        if !parent.valid(issued_at) {
            return Err(Error::Authentication);
        }
        if state
            .record
            .token
            .as_ref()
            .is_some_and(|t| t.fresh(issued_at))
        {
            return state.cached.clone().ok_or(Error::Authentication);
        }
        state.record.token = None;
        state.cached = None;
        self.0.store.save(&state.record).await?;
        let lease = match copilot::exchange(&self.0.http, config, parent).await {
            Ok(lease) => lease,
            Err(Error::Status(401 | 403)) => {
                self.pending(state).await?;
                return Err(Error::Authentication);
            }
            Err(error) => return Err(error),
        };
        let issued_at = now()?;
        let refresh_at = lease.validate(config, issued_at)?;
        // A finite upstream lifetime must still cover activation after IO.
        if !parent.valid(issued_at) {
            return Err(Error::Authentication);
        }
        let token = StoredToken {
            access: lease.token.clone(),
            refresh: None,
            issued_at,
            expires_at: lease.expires_at,
            scopes: self.0.config.scopes.clone(),
            refresh_at: Some(refresh_at),
        };
        let candidate = Record {
            version: 1,
            binding: state.record.binding.clone(),
            generation: state.record.generation,
            uncertain: false,
            token: Some(token),
            registration: None,
            copilot_parent: Some(parent.clone()),
            exchange_uncertain: false,
            delegation: None,
        };
        self.0.store.save(&candidate).await?;
        let cached = Arc::new(Zeroizing::new(lease.token.clone()));
        state.record = candidate;
        state.cached_delegation = None;
        state.cached = Some(cached.clone());
        Ok(cached)
    }

    pub(crate) async fn rejected(
        &self,
        token: &Arc<Zeroizing<String>>,
        error: &Error,
    ) -> Result<(), Error> {
        if !matches!(error, Error::Status(401)) {
            return Ok(());
        }
        let mut state = self.0.state.lock().await;
        if state
            .cached
            .as_ref()
            .is_some_and(|active| Arc::ptr_eq(active, token))
        {
            if self.0.config.copilot.is_some() {
                state.cached = None;
                state.record.token = None;
                self.0.store.save(&state.record).await?;
            } else {
                self.pending(&mut state).await?;
            }
        }
        Ok(())
    }

    pub(super) async fn activate(
        &self,
        state: &mut State,
        generation: u64,
        response: ProtocolResponse,
        previous_refresh: Option<(&str, Option<u64>)>,
        nonce: Option<&CsrfToken>,
    ) -> Result<Arc<Zeroizing<String>>, Error> {
        if generation != state.record.generation || response.token_type() != &BasicTokenType::Bearer
        {
            return Err(Error::Authentication);
        }
        if self.0.config.copilot.is_some() {
            return self
                .activate_copilot(state, response, previous_refresh)
                .await;
        }
        let lifetime = response
            .expires_in()
            .filter(|d| d.as_secs() > 30)
            .ok_or(Error::Authentication)?;
        let issued_at = now()?;
        let scopes = response
            .scopes()
            .map(|s| s.iter().map(|s| s.to_string()).collect())
            .unwrap_or_else(|| self.0.config.scopes.clone());
        if !scope_matches(&self.0.config.scopes, &scopes) {
            return Err(Error::Authentication);
        }
        if self.0.config.openai.is_some() && response.refresh_token().is_none() {
            return Err(Error::Authentication);
        }
        let registration = match self.identity_issuer() {
            Some(issuer) => {
                let saved = state
                    .record
                    .registration
                    .as_ref()
                    .ok_or(Error::Authentication)?;
                if self.0.config.openai.is_some() && nonce.is_some() && response.scopes().is_none()
                {
                    return Err(Error::Authentication);
                }
                Some(match response.extra_fields().id_token.as_deref() {
                    Some(id_token) => {
                        identity::verify(issuer, &self.0.http, saved, id_token, nonce).await?
                    }
                    None if nonce.is_none() && saved.subject.is_some() => saved.clone(),
                    None => return Err(Error::Authentication),
                })
            }
            None => None,
        };
        let access = response.access_token().secret();
        if !valid_access(access) {
            return Err(Error::Authentication);
        }
        let token = StoredToken {
            access: access.clone(),
            refresh: response
                .refresh_token()
                .map(|t| t.secret().to_owned())
                .or_else(|| previous_refresh.map(|(value, _)| value.to_owned())),
            issued_at,
            expires_at: issued_at
                .checked_add(lifetime.as_secs())
                .ok_or(Error::Authentication)?,
            scopes,
            refresh_at: None,
        };
        if !token.valid(&self.0.config.scopes) {
            return Err(Error::Authentication);
        }
        let candidate = Record {
            version: 1,
            binding: state.record.binding.clone(),
            generation,
            uncertain: false,
            token: Some(token),
            registration,
            copilot_parent: None,
            exchange_uncertain: false,
            delegation: None,
        };
        self.0.store.save(&candidate).await?;
        let cached = Arc::new(Zeroizing::new(access.clone()));
        state.record = candidate;
        state.cached_delegation = None;
        state.cached = Some(cached.clone());
        Ok(cached)
    }

    /// Clear credentials durably and invalidate pending login attempts.
    ///
    /// # Errors
    /// Returns a redacted error if the private token record cannot be updated.
    pub async fn logout(&self) -> Result<(), Error> {
        let revoke = self.clear_local().await?;
        if let (Some(issuer), Some((client, refresh))) = (self.revocation_issuer(), revoke) {
            identity::revoke(issuer, &self.0.http, &client, &refresh)
                .await
                .map_err(|_| Error::RevocationUnconfirmed)?;
        }
        Ok(())
    }

    async fn clear_local(&self) -> Result<Option<(String, Zeroizing<String>)>, Error> {
        let mut state = self.0.state.lock().await;
        let revoke = if self.revocation_issuer().is_some() {
            state
                .record
                .registration
                .as_ref()
                .and_then(|r| r.client_id.as_ref())
                .zip(state.record.token.as_ref().and_then(|t| t.refresh.as_ref()))
                .map(|(client, token)| (client.clone(), Zeroizing::new(token.clone())))
        } else {
            None
        };
        state.record.generation = state
            .record
            .generation
            .checked_add(1)
            .ok_or(Error::Authentication)?;
        state.record.token = None;
        state.record.copilot_parent = None;
        state.record.delegation = None;
        state.record.exchange_uncertain = false;
        state.cached_delegation = None;
        state.record.uncertain = true;
        state.cached = None;
        if let Some(registration) = &mut state.record.registration {
            registration.id_token.zeroize();
            registration.id_token = None;
            registration.nonce.zeroize();
            registration.nonce = None;
        }
        self.0.store.save(&state.record).await?;
        Ok(revoke)
    }

    /// Finish tracked store writes and stop admission of new credential work.
    /// A later process can reopen the durably stored credentials.
    pub async fn shutdown(&self) {
        self.0.store.shutdown().await;
    }

    pub(super) async fn begin(&self) -> Result<(u64, Option<Registration>), Error> {
        let mut state = self.0.state.lock().await;
        state.record.generation = state
            .record
            .generation
            .checked_add(1)
            .ok_or(Error::Authentication)?;
        self.0.store.save(&state.record).await?;
        Ok((state.record.generation, state.record.registration.clone()))
    }
}

pub(super) fn now() -> Result<u64, Error> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|t| t.as_secs())
        .map_err(|_| Error::Authentication)
}

fn protocol_client(config: &OAuthConfiguration, client_id: &str) -> Result<ProtocolClient, Error> {
    let mut client = oauth2::Client::new(ClientId::new(client_id.to_owned()))
        .set_auth_type(AuthType::RequestBody)
        .set_token_uri(TokenUrl::new(config.token_url.clone()).map_err(|_| Error::Configuration)?)
        .set_auth_uri_option(
            config
                .authorization_url
                .clone()
                .map(AuthUrl::new)
                .transpose()
                .map_err(|_| Error::Configuration)?,
        )
        .set_device_authorization_url_option(
            config
                .device_authorization_url
                .clone()
                .map(DeviceAuthorizationUrl::new)
                .transpose()
                .map_err(|_| Error::Configuration)?,
        );
    if let Some(redirect) = &config.redirect_uri {
        client = client.set_redirect_uri(
            RedirectUrl::new(redirect.clone()).map_err(|_| Error::Configuration)?,
        );
    }
    Ok(client)
}
