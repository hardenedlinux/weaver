// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Anthropic workload identity exchange outside the inference writer.
use super::{
    io_runtime::IoRuntime,
    wif_cache::{AccessToken, reusable},
};
use serde::Deserialize;
use std::{io::Read, sync::Mutex, time::Duration};
use tokio::time::Instant;
use weaver_contracts::{Error, Result, identifier};

pub(super) const MESSAGES: &str = "https://api.anthropic.com/v1/messages";
const EXCHANGE: &str = "https://api.anthropic.com/v1/oauth/token";
const LIMIT: usize = 16 * 1024;

/// Raw DTO boundary for the deployment WIF configuration.
/// Federation construction validates the issuer bindings before use.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnthropicWifConfig {
    pub assertion_file: std::path::PathBuf,
    pub federation_rule_id: String,
    pub organization_id: String,
    pub service_account_id: String,
    pub workspace_id: String,
}

pub(super) struct Federation {
    config: AnthropicWifConfig,
    cached: Mutex<Option<AccessToken>>,
}

#[derive(Deserialize)]
struct ExchangeResponse {
    access_token: String,
    token_type: String,
    expires_in: u64,
    scope: String,
}

impl Federation {
    pub(super) fn new(config: AnthropicWifConfig) -> Result<Self> {
        if !config.assertion_file.is_absolute() {
            return Err(Error::Invalid("WIF assertion path"));
        }
        for (value, prefix) in [
            (&config.federation_rule_id, "fdrl_"),
            (&config.service_account_id, "svac_"),
            (&config.workspace_id, "wrkspc_"),
        ] {
            identifier(value)?;
            if value.strip_prefix(prefix).is_none_or(str::is_empty) {
                return Err(Error::Invalid("WIF binding identifier"));
            }
        }
        identifier(&config.organization_id)?;
        Ok(Self {
            config,
            cached: Mutex::new(None),
        })
    }

    pub(super) fn token(
        &self,
        client: &reqwest::Client,
        runtime: &IoRuntime,
    ) -> Result<AccessToken> {
        let mut cached = self
            .cached
            .lock()
            .map_err(|_| Error::Conflict("WIF cache unavailable"))?;
        if let Some(token) = reusable(cached.as_ref()) {
            return Ok(token);
        }
        let mut assertion = String::new();
        std::fs::File::open(&self.config.assertion_file)
            .and_then(|file| file.take((LIMIT + 1) as u64).read_to_string(&mut assertion))
            .map_err(|_| Error::Invalid("WIF assertion file"))?;
        let jwt = assertion.trim();
        if assertion.len() > LIMIT || jwt.is_empty() || !jwt.bytes().all(|b| b.is_ascii_graphic()) {
            return Err(Error::Invalid("WIF assertion bound"));
        }
        let request = serde_json::to_vec(&serde_json::json!({
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": jwt,
            "federation_rule_id": self.config.federation_rule_id,
            "organization_id": self.config.organization_id,
            "service_account_id": self.config.service_account_id,
            "workspace_id": self.config.workspace_id
        }))?;
        let started = Instant::now();
        let response = runtime.wait(started + Duration::from_secs(5), async {
            let mut reply = client
                .post(EXCHANGE)
                .header("content-type", "application/json")
                .body(request)
                .send()
                .await
                .map_err(|_| Error::Conflict("WIF exchange unavailable"))?;
            if reply.status() != reqwest::StatusCode::OK {
                return Err(Error::Denied);
            }
            let mut body = Vec::new();
            while let Some(chunk) = reply
                .chunk()
                .await
                .map_err(|_| Error::Conflict("WIF exchange interrupted"))?
            {
                if chunk.len() > LIMIT - body.len() {
                    return Err(Error::Invalid("WIF response bound"));
                }
                body.extend_from_slice(&chunk);
            }
            weaver_contracts::decode::<ExchangeResponse>(&body)
                .map_err(|_| Error::Invalid("WIF response shape"))
        })?;
        let token = validate_response(response, started)?;
        *cached = Some(token.clone());
        Ok(token)
    }
}

fn validate_response(response: ExchangeResponse, started: Instant) -> Result<AccessToken> {
    if response.token_type != "Bearer"
        || response.scope != "workspace:inference"
        || !(1..=3600).contains(&response.expires_in)
        || !response.access_token.starts_with("sk-ant-oat01-")
        || response.access_token.len() > 4096
        || !response.access_token.bytes().all(|b| b.is_ascii_graphic())
    {
        return Err(Error::Denied);
    }
    let expires = started + Duration::from_secs(response.expires_in);
    if expires.saturating_duration_since(Instant::now()) <= Duration::from_secs(10) {
        return Err(Error::Denied);
    }
    Ok(AccessToken {
        value: response.access_token.into(),
        expires,
    })
}

#[cfg(test)]
#[path = "../../tests/unit/provider_wif.rs"]
mod tests;
