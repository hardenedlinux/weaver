// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Copilot's non-consuming API lease exchange, bound to a trusted model base.

use super::{http::OAuthHttp, settings::CopilotSettings};
use crate::{Endpoint, Error, Protocol};
use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ParentCredential {
    pub access: String,
    pub issued_at: u64,
    pub expires_at: Option<u64>,
    pub refresh: Option<String>,
    pub refresh_expires_at: Option<u64>,
}

impl Drop for ParentCredential {
    fn drop(&mut self) {
        self.access.zeroize();
        self.refresh.zeroize();
    }
}

impl ParentCredential {
    pub fn well_formed(&self) -> bool {
        valid_secret(&self.access)
            && self.expires_at.is_none_or(|at| at > self.issued_at)
            && self.refresh.as_deref().is_none_or(valid_secret)
            && self
                .refresh_expires_at
                .is_none_or(|at| at > 0 && self.refresh.is_some())
    }

    pub fn valid(&self, now: u64) -> bool {
        // Format checks belong to load/activation; warm model calls only check time.
        now >= self.issued_at && self.expires_at.is_none_or(|expiry| now < expiry)
    }

    pub fn refresh_token(&self, now: u64) -> Option<&str> {
        self.refresh.as_deref().filter(|value| {
            valid_secret(value)
                && now >= self.issued_at
                && self.refresh_expires_at.is_none_or(|expiry| now < expiry)
        })
    }
}

#[derive(Deserialize)]
pub(super) struct ApiLease {
    pub token: String,
    pub expires_at: u64,
    pub refresh_in: u64,
    #[serde(default)]
    endpoints: Option<ApiEndpoint>,
}

#[derive(Deserialize)]
struct ApiEndpoint {
    api: Option<String>,
}

impl Drop for ApiLease {
    fn drop(&mut self) {
        self.token.zeroize();
    }
}

impl ApiLease {
    pub fn validate(&self, config: &CopilotSettings, now: u64) -> Result<u64, Error> {
        let refresh_at = now
            .checked_add(self.refresh_in)
            .filter(|at| *at > now)
            .ok_or(Error::Authentication)?;
        if !valid_secret(&self.token) || self.expires_at <= now.saturating_add(30) {
            return Err(Error::Authentication);
        }
        if let Some(base) = self.endpoints.as_ref().and_then(|e| e.api.as_deref()) {
            let returned = Endpoint::new(Protocol::OpenAi, base)?;
            let expected = Endpoint::new(Protocol::OpenAi, &config.api_base)?;
            if returned.url.query().is_some()
                || returned.url.as_str().trim_end_matches('/')
                    != expected.url.as_str().trim_end_matches('/')
            {
                return Err(Error::Authentication);
            }
        }
        Ok(refresh_at)
    }
}

pub(super) fn valid_secret(value: &str) -> bool {
    !value.is_empty() && value.len() <= 16 * 1024 && value.bytes().all(|c| c.is_ascii_graphic())
}

pub(crate) fn headers() -> reqwest::header::HeaderMap {
    let mut headers = reqwest::header::HeaderMap::new();
    for (name, value) in [
        ("user-agent", concat!("weaver/", env!("CARGO_PKG_VERSION"))),
        (
            "editor-version",
            concat!("weaver/", env!("CARGO_PKG_VERSION")),
        ),
        (
            "editor-plugin-version",
            concat!("weaver/", env!("CARGO_PKG_VERSION")),
        ),
        ("copilot-integration-id", "vscode-chat"),
        ("x-github-api-version", "2025-04-01"),
    ] {
        headers.insert(name, reqwest::header::HeaderValue::from_static(value));
    }
    headers
}

pub(super) async fn exchange(
    http: &OAuthHttp,
    config: &CopilotSettings,
    parent: &ParentCredential,
) -> Result<ApiLease, Error> {
    let mut authorization =
        oauth2::http::HeaderValue::from_str(&format!("token {}", parent.access))
            .map_err(|_| Error::Authentication)?;
    authorization.set_sensitive(true);
    let request = oauth2::http::Request::builder()
        .uri(&config.api_token_url)
        .header("accept", "application/json")
        .header("authorization", authorization)
        .body(Vec::new())
        .map_err(|_| Error::Authentication)?;
    let response = http.request(request).await?;
    match response.status().as_u16() {
        200 => serde_json::from_slice(response.body()).map_err(|_| Error::Authentication),
        401 | 403 => Err(Error::Status(response.status().as_u16())),
        _ => Err(Error::Authentication),
    }
}

#[cfg(test)]
#[path = "../../tests/unit/copilot.rs"]
mod tests;
