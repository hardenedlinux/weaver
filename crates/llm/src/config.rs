// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Trusted downstream connection profiles, prepared before model calls.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use serde::Deserialize;
use zeroize::Zeroizing;

use crate::{
    Authentication, Client, Completion, Endpoint, Error, Message, Options, Protocol, Request,
    TurnStream,
    files::{SECRET_LIMIT, SecretReference, read_bounded},
    oauth::{
        CopilotConfiguration, ExchangeConfiguration, OAuthConfiguration, OAuthSession,
        OidcConfiguration, OpenAiConfiguration, copilot_headers, discover_oidc,
    },
    operation::{OperationMaterial, OperationSettings, PreparedOperation},
};

const CONFIG_LIMIT: u64 = 256 * 1024;

/// A caller-selected, trusted TOML file. No configuration is discovered implicitly.
pub struct Configuration {
    profiles: BTreeMap<String, Profile>,
    directory: PathBuf,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Document {
    profiles: BTreeMap<String, Profile>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Profile {
    Direct {
        protocol: WireProtocol,
        #[serde(default)]
        authentication: Authentication,
        endpoint: Option<String>,
        model: Option<String>,
        timeout_ms: u64,
        max_response_bytes: usize,
        credential: Option<Credential>,
    },
    Delegated {
        endpoint: String,
        timeout_ms: u64,
        identity: OidcConfiguration,
        exchange: Box<ExchangeConfiguration>,
        operation: Option<OperationSettings>,
    },
}

#[derive(Clone, Copy, Deserialize)]
enum WireProtocol {
    #[serde(rename = "openai-chat-completions")]
    OpenAi,
    #[serde(rename = "openai-responses")]
    OpenAiResponses,
    #[serde(rename = "anthropic-messages")]
    Anthropic,
}

impl From<WireProtocol> for Protocol {
    fn from(value: WireProtocol) -> Self {
        match value {
            WireProtocol::OpenAi => Self::OpenAi,
            WireProtocol::OpenAiResponses => Self::OpenAiResponses,
            WireProtocol::Anthropic => Self::Anthropic,
        }
    }
}

#[derive(Deserialize)]
#[serde(untagged, deny_unknown_fields)]
enum Credential {
    Static(SecretReference),
    OAuth { oauth: Box<OAuthConfiguration> },
    OpenAi { openai: OpenAiConfiguration },
    Copilot { copilot: CopilotConfiguration },
    Oidc { oidc: OidcConfiguration },
}

impl Configuration {
    /// Read a trusted `weaver.toml` without resolving any credentials.
    ///
    /// The Harness must supply this path from trusted startup settings.
    /// Repository and model-supplied files must not select this path.
    ///
    /// # Errors
    /// Rejects unreadable, oversized or malformed files, unknown fields and
    /// unsupported profile kinds. Errors contain no file content or paths.
    pub async fn load(path: impl AsRef<Path>) -> Result<Self, Error> {
        let path = path.as_ref();
        let bytes = read_bounded(path, CONFIG_LIMIT, false).await?;
        let text = std::str::from_utf8(&bytes).map_err(|_| Error::Configuration)?;
        let document: Document = toml::from_str(text).map_err(|_| Error::Configuration)?;
        if document.profiles.is_empty() {
            return Err(Error::Configuration);
        }
        let config = Self {
            profiles: document.profiles,
            directory: path.parent().unwrap_or_else(|| Path::new(".")).to_owned(),
        };
        if config
            .credential_environment()
            .any(|name| name.is_empty() || name.contains(['=', '\0']))
        {
            return Err(Error::Configuration);
        }
        Ok(config)
    }

    /// Names the Harness must exclude from tool subprocess environments.
    /// Includes static, actor and client-auth references without reading values.
    pub fn credential_environment(&self) -> impl Iterator<Item = &str> {
        self.profiles.values().flat_map(|profile| {
            let mut names = Vec::new();
            match profile {
                Profile::Direct {
                    credential: Some(Credential::Static(source)),
                    ..
                } => {
                    names.extend(source.environment());
                }
                Profile::Direct {
                    protocol: WireProtocol::Anthropic,
                    credential: None,
                    ..
                } => {
                    names.push("ANTHROPIC_API_KEY");
                }
                Profile::Delegated {
                    exchange,
                    operation,
                    ..
                } => {
                    names.extend(operation.as_ref().and_then(|o| o.credential.environment()));
                    names.extend(
                        exchange
                            .client_secret
                            .as_ref()
                            .and_then(SecretReference::environment),
                    );
                    names.extend(exchange.actor.as_ref().and_then(|a| a.token.environment()));
                }
                Profile::Direct { .. } => {}
            }
            names
        })
    }

    /// Prepare an OIDC identity and RFC 8693 exchange for one operation resource.
    /// The returned owner acquires an additional delegated credential; it cannot
    /// publish grants or replace the operation/mTLS identities.
    ///
    /// # Errors
    /// Rejects a non-delegated profile, unsafe binding or secret source.
    pub async fn prepare_delegation(&self, name: &str) -> Result<OAuthSession, Error> {
        self.prepare_delegated(name)
            .await
            .map(|(identity, _, _)| identity)
    }

    /// Prepare the operation TLS/bearer and delegated identity from one profile.
    ///
    /// # Errors
    /// Rejects absent operation settings, non-private keys or unbound identities.
    pub async fn prepare_operation(&self, name: &str) -> Result<PreparedOperation, Error> {
        let (identity, endpoint, material) = self.prepare_delegated(name).await?;
        let material = material.ok_or(Error::Configuration)?;
        Ok(PreparedOperation {
            identity,
            endpoint,
            server_name: material.server_name,
            ca: material.ca,
            certificate: material.certificate,
            key: material.key,
            operation_bearer: material.bearer,
        })
    }

    async fn prepare_delegated(
        &self,
        name: &str,
    ) -> Result<(OAuthSession, String, Option<OperationMaterial>), Error> {
        let Profile::Delegated {
            endpoint,
            timeout_ms,
            identity,
            exchange,
            operation,
        } = self.profiles.get(name).ok_or(Error::Configuration)?
        else {
            return Err(Error::Configuration);
        };
        let endpoint = Endpoint::new(Protocol::OpenAi, endpoint)?.url.to_string();
        let material = match operation {
            Some(operation) => Some(operation.prepare(&self.directory).await?),
            None => None,
        };
        let binding = material.as_ref().map(|m| m.binding.clone());
        let client = Client::new(Duration::from_millis(*timeout_ms), 64 * 1024)?;
        let mut config = discover_oidc(identity.clone(), client.http.clone()).await?;
        config.token_file = self.directory.join(&config.token_file);
        let identity = OAuthSession::open_exchange(
            config,
            &endpoint,
            client.http,
            exchange,
            &self.directory,
            binding,
        )
        .await?;
        Ok((identity, endpoint, material))
    }

    /// Validate and prepare exactly one profile, resolving its credential once.
    ///
    /// Call again after rotation and replace the handle used for new calls.
    /// Existing streams retain their own HTTP exchange.
    ///
    /// # Errors
    /// Rejects an unknown profile, invalid destination, limits or credential.
    /// Mounted secrets must be regular files and private to their Unix owner.
    pub async fn prepare(&self, name: &str) -> Result<PreparedProfile, Error> {
        let Profile::Direct {
            protocol,
            authentication,
            endpoint,
            model,
            timeout_ms,
            max_response_bytes,
            credential,
        } = self.profiles.get(name).ok_or(Error::Configuration)?
        else {
            return Err(Error::Configuration);
        };
        let (endpoint, model) = resolve_direct_target(
            (*protocol).into(),
            endpoint.as_deref(),
            model.as_deref(),
            |name| std::env::var(name).ok(),
        )?;
        let mut endpoint =
            Endpoint::new((*protocol).into(), &endpoint)?.with_authentication(*authentication);
        if model.trim().is_empty() || model.len() > 1024 {
            return Err(Error::Configuration);
        }
        let client = Client::new(Duration::from_millis(*timeout_ms), *max_response_bytes)?;
        let default_credential = matches!(protocol, WireProtocol::Anthropic).then(|| {
            Credential::Static(SecretReference::Environment {
                env: "ANTHROPIC_API_KEY".into(),
            })
        });
        let credential = credential
            .as_ref()
            .or(default_credential.as_ref())
            .ok_or(Error::Configuration)?;
        let credential = match credential {
            Credential::Static(source) => {
                PreparedCredential::static_value(source.resolve(&self.directory).await?)?
            }
            Credential::OAuth { oauth } => {
                if oauth.openai.is_some()
                    || oauth.copilot.is_some()
                    || oauth.oidc.is_some()
                    || oauth.exchange.is_some()
                {
                    return Err(Error::Configuration);
                }
                self.prepare_oauth(
                    oauth.as_ref().clone(),
                    &mut endpoint,
                    (*protocol).into(),
                    &model,
                    &client,
                )
                .await?
            }
            Credential::OpenAi { openai } => {
                self.prepare_oauth(
                    openai.clone().into_oauth(),
                    &mut endpoint,
                    (*protocol).into(),
                    &model,
                    &client,
                )
                .await?
            }
            Credential::Copilot { copilot } => {
                self.prepare_oauth(
                    copilot.clone().into_oauth(),
                    &mut endpoint,
                    (*protocol).into(),
                    &model,
                    &client,
                )
                .await?
            }
            Credential::Oidc { oidc } => {
                let oauth = discover_oidc(oidc.clone(), client.http.clone()).await?;
                self.prepare_oauth(oauth, &mut endpoint, (*protocol).into(), &model, &client)
                    .await?
            }
        };
        Ok(PreparedProfile {
            client,
            endpoint,
            model,
            credential,
        })
    }

    async fn prepare_oauth(
        &self,
        mut oauth: OAuthConfiguration,
        endpoint: &mut Endpoint,
        protocol: Protocol,
        model: &str,
        client: &Client,
    ) -> Result<PreparedCredential, Error> {
        if oauth.oidc.is_some() {
            let base = Endpoint::new(
                protocol,
                oauth.resource.as_ref().ok_or(Error::Configuration)?,
            )?;
            let prefix = format!("{}/", base.url.path().trim_end_matches('/'));
            if endpoint.url.origin() != base.url.origin()
                || !(endpoint.url.path() == base.url.path()
                    || endpoint.url.path().starts_with(&prefix))
                || base.url.query().is_some()
                || endpoint.url.query().is_some()
            {
                return Err(Error::Configuration);
            }
        }
        if let Some(copilot) = &oauth.copilot {
            let base = Endpoint::new(protocol, &copilot.api_base)?;
            let prefix = format!("{}/", base.url.path().trim_end_matches('/'));
            if protocol != Protocol::OpenAi
                || endpoint.url.origin() != base.url.origin()
                || !endpoint.url.path().starts_with(&prefix)
                || endpoint.url.query().is_some()
                || base.url.query().is_some()
            {
                return Err(Error::Configuration);
            }
            endpoint.headers = copilot_headers();
        }
        if let Some(identity) = &mut oauth.openai {
            let resource = Endpoint::new(
                protocol,
                oauth.resource.as_ref().ok_or(Error::Configuration)?,
            )?;
            let prefix = format!("{}/", resource.url.path().trim_end_matches('/'));
            if protocol != Protocol::OpenAiResponses
                || endpoint.url.origin() != resource.url.origin()
                || !(endpoint.url.path() == resource.url.path()
                    || endpoint.url.path().starts_with(&prefix))
                || resource.url.query().is_some()
            {
                return Err(Error::Configuration);
            }
            identity.host_id_file = self.directory.join(&identity.host_id_file);
            if identity.host_id_file == self.directory.join(&oauth.token_file) {
                return Err(Error::Configuration);
            }
        }
        *endpoint = endpoint.clone().with_authentication(Authentication::Bearer);
        oauth.token_file = self.directory.join(&oauth.token_file);
        let binding = format!("{protocol:?}\n{}\n{model}", endpoint.url);
        Ok(PreparedCredential::OAuth(
            OAuthSession::open(oauth, &binding, client.http.clone()).await?,
        ))
    }
}

/// Resolve an explicit model and endpoint, filling absent Anthropic values from
/// the supplied environment. Explicit configuration always takes precedence.
///
/// # Errors
/// Returns a configuration error when a required value is missing or invalid.
pub fn resolve_direct_target(
    protocol: Protocol,
    endpoint: Option<&str>,
    model: Option<&str>,
    read_env: impl Fn(&str) -> Option<String>,
) -> Result<(String, String), Error> {
    let model = match model {
        Some(value) => value.to_owned(),
        None if protocol == Protocol::Anthropic => {
            read_env("ANTHROPIC_MODEL").ok_or(Error::Configuration)?
        }
        None => return Err(Error::Configuration),
    };
    let endpoint = match endpoint {
        Some(value) => value.to_owned(),
        None if protocol == Protocol::Anthropic => {
            let base = read_env("ANTHROPIC_BASE_URL").ok_or(Error::Configuration)?;
            if base.len() > 4096 {
                return Err(Error::Configuration);
            }
            let mut url = reqwest::Url::parse(&base).map_err(|_| Error::Configuration)?;
            if url.query().is_some() || url.fragment().is_some() {
                return Err(Error::Configuration);
            }
            let path = url.path().trim_end_matches('/');
            let path = if path.ends_with("/v1/messages") {
                path.to_owned()
            } else if path.ends_with("/v1") {
                format!("{path}/messages")
            } else {
                format!("{path}/v1/messages")
            };
            url.set_path(&path);
            url.to_string()
        }
        None => return Err(Error::Configuration),
    };
    Ok((endpoint, model))
}

/// An immutable connection with a pooled client and a private credential.
/// Reload trusted configuration to rotate or change its destination.
pub struct PreparedProfile {
    client: Client,
    endpoint: Endpoint,
    model: String,
    credential: PreparedCredential,
}

enum PreparedCredential {
    Static(Arc<Zeroizing<String>>),
    OAuth(OAuthSession),
}

impl PreparedCredential {
    fn static_value(secret: Zeroizing<String>) -> Result<Self, Error> {
        if secret.is_empty() || secret.len() as u64 > SECRET_LIMIT || secret.trim() != *secret {
            return Err(Error::Configuration);
        }
        reqwest::header::HeaderValue::from_str(&secret).map_err(|_| Error::Configuration)?;
        Ok(Self::Static(Arc::new(secret)))
    }

    async fn token(&self) -> Result<Arc<Zeroizing<String>>, Error> {
        match self {
            Self::Static(value) => Ok(value.clone()),
            Self::OAuth(session) => session.access_token().await,
        }
    }

    async fn rejected(&self, token: &Arc<Zeroizing<String>>, error: &Error) -> Result<(), Error> {
        if let Self::OAuth(session) = self {
            session.rejected(token, error).await?;
        }
        Ok(())
    }
}

impl std::fmt::Debug for PreparedProfile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedProfile").finish_non_exhaustive()
    }
}

impl PreparedProfile {
    /// Model identity bound to this prepared connection.
    pub fn model(&self) -> &str {
        &self.model
    }

    /// Access the shared login, refresh and logout owner of an OAuth profile.
    pub fn oauth(&self) -> Option<&OAuthSession> {
        match &self.credential {
            PreparedCredential::OAuth(session) => Some(session),
            PreparedCredential::Static(_) => None,
        }
    }
    /// Execute a bounded completion using the configured destination and model.
    ///
    /// # Errors
    /// Returns the existing client validation, transport and protocol errors.
    pub async fn complete(
        &self,
        messages: &[Message],
        options: &Options,
    ) -> Result<Completion, Error> {
        let secret = self.credential.token().await?;
        let result = self
            .client
            .complete(
                &self.endpoint,
                &secret,
                &Request {
                    model: &self.model,
                    messages,
                    options,
                },
            )
            .await;
        if let Err(error) = &result {
            self.credential.rejected(&secret, error).await?;
        }
        result
    }

    /// Open the existing pull-based turn stream with the prepared configuration.
    ///
    /// # Errors
    /// Returns the existing client validation, transport and protocol errors.
    pub async fn stream_turn(
        &self,
        messages: &[Message],
        options: &Options,
    ) -> Result<TurnStream, Error> {
        let secret = self.credential.token().await?;
        let result = self
            .client
            .stream_turn(
                &self.endpoint,
                &secret,
                &Request {
                    model: &self.model,
                    messages,
                    options,
                },
            )
            .await;
        if let Err(error) = &result {
            self.credential.rejected(&secret, error).await?;
        }
        result
    }
}
