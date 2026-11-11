// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Raw trusted TOML settings, validated by the credential owner before use.

use super::exchange_types::ExchangeSettings;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct OAuthConfiguration {
    pub client_id: String,
    pub token_url: String,
    pub authorization_url: Option<String>,
    pub device_authorization_url: Option<String>,
    pub redirect_uri: Option<String>,
    pub resource: Option<String>,
    pub scopes: Vec<String>,
    pub token_file: PathBuf,
    pub login_timeout_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub openai: Option<OpenAiIdentitySettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub copilot: Option<CopilotSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oidc: Option<OidcSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exchange: Option<ExchangeSettings>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct OpenAiIdentitySettings {
    pub issuer: String,
    pub agent_name: String,
    pub host_id_file: PathBuf,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct OpenAiConfiguration {
    pub agent_name: String,
    pub token_file: PathBuf,
    pub host_id_file: PathBuf,
    pub redirect_uri: String,
    #[serde(default = "default_issuer")]
    pub issuer: String,
    #[serde(default = "default_resource")]
    pub resource: String,
    #[serde(default = "default_login_budget")]
    pub login_timeout_ms: u64,
}

impl OpenAiConfiguration {
    pub fn into_oauth(self) -> OAuthConfiguration {
        let issuer = self.issuer.trim_end_matches('/').to_owned();
        OAuthConfiguration {
            client_id: "dynamic_agent_client".into(),
            token_url: format!("{issuer}/api/accounts/oauth/token"),
            authorization_url: Some(format!("{issuer}/api/accounts/authorize")),
            device_authorization_url: None,
            redirect_uri: Some(self.redirect_uri),
            resource: Some(self.resource),
            scopes: [
                "openid",
                "profile",
                "email",
                "offline_access",
                "resource.invoke",
                "chatgpt.tokens.use.direct",
            ]
            .map(str::to_owned)
            .to_vec(),
            token_file: self.token_file,
            login_timeout_ms: self.login_timeout_ms,
            openai: Some(OpenAiIdentitySettings {
                issuer,
                agent_name: self.agent_name,
                host_id_file: self.host_id_file,
            }),
            copilot: None,
            oidc: None,
            exchange: None,
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CopilotSettings {
    pub api_token_url: String,
    pub api_base: String,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CopilotConfiguration {
    pub client_id: String,
    pub token_file: PathBuf,
    #[serde(default = "github_device_url")]
    pub device_authorization_url: String,
    #[serde(default = "github_token_url")]
    pub token_url: String,
    #[serde(default = "copilot_token_url")]
    pub api_token_url: String,
    pub api_base: String,
    #[serde(default = "default_login_budget")]
    pub login_timeout_ms: u64,
}

impl CopilotConfiguration {
    pub fn into_oauth(self) -> OAuthConfiguration {
        OAuthConfiguration {
            client_id: self.client_id,
            token_url: self.token_url,
            authorization_url: None,
            device_authorization_url: Some(self.device_authorization_url),
            redirect_uri: None,
            resource: None,
            scopes: vec!["read:user".into()],
            token_file: self.token_file,
            login_timeout_ms: self.login_timeout_ms,
            openai: None,
            copilot: Some(CopilotSettings {
                api_token_url: self.api_token_url,
                api_base: self.api_base,
            }),
            oidc: None,
            exchange: None,
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct OidcSettings {
    pub issuer: String,
    pub revoke_on_logout: bool,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct OidcConfiguration {
    pub issuer: String,
    pub client_id: String,
    pub redirect_uri: String,
    pub resource: String,
    pub scopes: Vec<String>,
    pub token_file: PathBuf,
    #[serde(default)]
    pub revoke_on_logout: bool,
    #[serde(default = "default_login_budget")]
    pub login_timeout_ms: u64,
}

fn github_device_url() -> String {
    "https://github.com/login/device/code".into()
}
fn github_token_url() -> String {
    "https://github.com/login/oauth/access_token".into()
}
fn copilot_token_url() -> String {
    "https://api.github.com/copilot_internal/v2/token".into()
}

fn default_issuer() -> String {
    "https://auth.openai.com".into()
}
fn default_resource() -> String {
    "https://api.openai.com/v1".into()
}
fn default_login_budget() -> u64 {
    300_000
}
