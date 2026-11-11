// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Consumed browser/device attempts delegate state commits to the shared owner.

use super::{
    identity::Registration,
    owner::{OAuthSession, ProtocolClient},
};
use crate::{Endpoint, Error, Protocol};
use oauth2::{
    AuthorizationCode, CsrfToken, PkceCodeChallenge, PkceCodeVerifier, Scope,
    StandardDeviceAuthorizationResponse,
};
use std::time::Duration;

impl OAuthSession {
    /// Prepare S256 PKCE and state for the Harness's browser and callback listener.
    ///
    /// # Errors
    /// Rejects a profile without an authorization endpoint or callback URI.
    pub async fn start_authorization(&self) -> Result<AuthorizationAttempt, Error> {
        if self.0.config.redirect_uri.is_none() {
            return Err(Error::Configuration);
        }
        let (generation, registration) = self.begin().await?;
        let client = self.protocol_client(registration.as_ref())?;
        let nonce = self.identity_issuer().map(|_| CsrfToken::new_random());
        let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
        let (url, state) =
            self.authorization_target(&client, challenge, registration.as_ref(), nonce.as_ref())?;
        Ok(AuthorizationAttempt {
            session: self.clone(),
            generation,
            url,
            state,
            verifier,
            registration,
            nonce,
            deadline: tokio::time::Instant::now()
                .checked_add(Duration::from_millis(self.0.config.login_timeout_ms))
                .ok_or(Error::Configuration)?,
        })
    }

    fn authorization_target(
        &self,
        client: &ProtocolClient,
        challenge: PkceCodeChallenge,
        registration: Option<&Registration>,
        nonce: Option<&CsrfToken>,
    ) -> Result<(oauth2::url::Url, CsrfToken), Error> {
        let mut request = client
            .authorize_url(CsrfToken::new_random)
            .map_err(|_| Error::Configuration)?
            .set_pkce_challenge(challenge);
        for scope in &self.0.config.scopes {
            request = request.add_scope(Scope::new(scope.clone()));
        }
        if let Some(resource) = &self.0.config.resource {
            request = request.add_extra_param("resource", resource);
        }
        if let Some(nonce) = nonce {
            request = request.add_extra_param("nonce", nonce.secret());
        }
        if let Some(config) = &self.0.config.openai {
            let saved = registration.as_ref().ok_or(Error::Authentication)?;
            request = request.add_extra_param("ext_agent_host_id", &saved.host_id);
            if saved.client_id.is_none() {
                request = request.add_extra_param("agent_name_hint", &config.agent_name);
            } else {
                if let Some(token) = &saved.id_token {
                    request = request.add_extra_param("id_token_hint", token);
                }
                if let Some(email) = &saved.email {
                    request = request.add_extra_param("login_hint", email);
                }
            }
        }
        if self.0.config.oidc.is_some()
            && let Some(token) = registration.and_then(|r| r.id_token.as_deref())
        {
            request = request.add_extra_param("id_token_hint", token);
        }
        Ok(request.url())
    }

    /// Obtain the user-code challenge for the Harness to display.
    ///
    /// # Errors
    /// Returns a redacted error for an unsupported or failed device flow.
    pub async fn start_device_authorization(&self) -> Result<DeviceAttempt, Error> {
        if self.identity_issuer().is_some() {
            return Err(Error::Configuration);
        }
        let (generation, _) = self.begin().await?;
        let mut request = self
            .0
            .client
            .exchange_device_code()
            .map_err(|_| Error::Configuration)?;
        for scope in &self.0.config.scopes {
            request = request.add_scope(Scope::new(scope.clone()));
        }
        if let Some(resource) = &self.0.config.resource {
            request = request.add_extra_param("resource", resource);
        }
        let started = tokio::time::Instant::now();
        let details: StandardDeviceAuthorizationResponse = request
            .request_async(&self.0.http)
            .await
            .map_err(|_| Error::Authentication)?;
        Endpoint::new(Protocol::OpenAi, details.verification_uri().as_str())?;
        Ok(DeviceAttempt {
            session: self.clone(),
            generation,
            details,
            started,
        })
    }
}

/// One browser authorization attempt. Consumption prevents code reuse.
pub struct AuthorizationAttempt {
    session: OAuthSession,
    generation: u64,
    url: oauth2::url::Url,
    state: CsrfToken,
    verifier: PkceCodeVerifier,
    registration: Option<Registration>,
    nonce: Option<CsrfToken>,
    deadline: tokio::time::Instant,
}

impl AuthorizationAttempt {
    /// URL to open in the Harness's system browser.
    pub fn authorization_url(&self) -> &str {
        self.url.as_str()
    }

    /// Validate the complete callback URL and exchange its code once.
    ///
    /// # Errors
    /// Rejects substituted callbacks, duplicate parameters, stale attempts,
    /// rejected consent and protocol errors without exposing their contents.
    pub async fn finish(self, callback: &str) -> Result<(), Error> {
        if tokio::time::Instant::now() >= self.deadline {
            return Err(Error::Authentication);
        }
        let (code, returned_client) = self.callback_code(callback)?;
        let mut state = self.session.0.state.lock().await;
        if state.record.generation != self.generation {
            return Err(Error::Authentication);
        }
        state.record.registration = self.callback_registration(returned_client.as_deref())?;
        let client = self
            .session
            .protocol_client(state.record.registration.as_ref())?;
        self.session.pending(&mut state).await?;
        let remaining = self
            .deadline
            .checked_duration_since(tokio::time::Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or(Error::Authentication)?;
        let mut request = client.exchange_code(code).set_pkce_verifier(self.verifier);
        if let Some(resource) = &self.session.0.config.resource {
            request = request.add_extra_param("resource", resource);
        }
        tokio::time::timeout(remaining, async {
            let response = request
                .request_async(&self.session.0.http)
                .await
                .map_err(|_| Error::Authentication)?;
            self.session
                .activate(
                    &mut state,
                    self.generation,
                    response,
                    None,
                    self.nonce.as_ref(),
                )
                .await?;
            Ok(())
        })
        .await
        .map_err(|_| Error::Authentication)?
    }

    fn callback_registration(&self, returned: Option<&str>) -> Result<Option<Registration>, Error> {
        match &self.registration {
            Some(saved) => {
                let mut saved = saved.clone();
                saved.client_id = Some(saved.callback_client(returned)?);
                Ok(Some(saved))
            }
            None if returned.is_none_or(|id| id == self.session.0.config.client_id) => Ok(None),
            _ => Err(Error::Authentication),
        }
    }

    fn callback_code(&self, callback: &str) -> Result<(AuthorizationCode, Option<String>), Error> {
        if callback.len() > 16 * 1024 {
            return Err(Error::Authentication);
        }
        let mut callback = oauth2::url::Url::parse(callback).map_err(|_| Error::Authentication)?;
        let expected = self
            .session
            .0
            .config
            .redirect_uri
            .as_ref()
            .ok_or(Error::Configuration)?;
        let mut values = std::collections::BTreeMap::new();
        for (key, value) in callback.query_pairs() {
            if values.insert(key.to_string(), value.to_string()).is_some() {
                return Err(Error::Authentication);
            }
        }
        callback.set_query(None);
        if callback.as_str() != expected
            || CsrfToken::new(values.remove("state").ok_or(Error::Authentication)?) != self.state
            || values.contains_key("error")
        {
            return Err(Error::Authentication);
        }
        Ok((
            AuthorizationCode::new(
                values
                    .remove("code")
                    .filter(|v| !v.is_empty())
                    .ok_or(Error::Authentication)?,
            ),
            values.remove("client_id"),
        ))
    }
}

/// Device authorization challenge. Device codes remain private to this handle.
pub struct DeviceAttempt {
    session: OAuthSession,
    generation: u64,
    details: StandardDeviceAuthorizationResponse,
    started: tokio::time::Instant,
}

impl DeviceAttempt {
    /// URL the Harness displays to the user.
    pub fn verification_uri(&self) -> &str {
        self.details.verification_uri().as_str()
    }
    /// Short code the Harness displays for this login.
    pub fn user_code(&self) -> &str {
        self.details.user_code().secret()
    }

    /// Poll within the configured deadline using the provider's interval.
    ///
    /// # Errors
    /// Returns a redacted error on cancellation, denial, expiry or stale login.
    pub async fn finish(self) -> Result<(), Error> {
        let budget = self.details.expires_in().min(Duration::from_millis(
            self.session.0.config.login_timeout_ms,
        ));
        if self.started.elapsed() >= budget {
            return Err(Error::Authentication);
        }
        let mut state = self.session.0.state.lock().await;
        if state.record.generation != self.generation {
            return Err(Error::Authentication);
        }
        self.session.pending(&mut state).await?;
        let remaining = budget
            .checked_sub(self.started.elapsed())
            .filter(|d| !d.is_zero())
            .ok_or(Error::Authentication)?;
        let mut request = self
            .session
            .0
            .client
            .exchange_device_access_token(&self.details);
        if let Some(resource) = &self.session.0.config.resource {
            request = request.add_extra_param("resource", resource);
        }
        tokio::time::timeout(remaining, async {
            let response = request
                .request_async(&self.session.0.http, tokio::time::sleep, Some(remaining))
                .await
                .map_err(|_| Error::Authentication)?;
            self.session
                .activate(&mut state, self.generation, response, None, None)
                .await?;
            Ok(())
        })
        .await
        .map_err(|_| Error::Authentication)?
    }
}
