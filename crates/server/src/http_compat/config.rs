// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Optional loopback capability; no default credential or source permission.
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::net::SocketAddr;
use tokio::io::AsyncReadExt;
use weaver_contracts::{Error, Result};

/// One deployment-selected Session and a distinct local operation credential.
/// This profile cannot register sources or select another caller principal.
#[derive(Clone)]
pub struct HttpProfile {
    pub session: String,
    pub token_sha256: [u8; 32],
}
impl HttpProfile {
    pub(crate) fn validate(&self, gateway: &crate::grpc::Gateway) -> Result<()> {
        weaver_contracts::identifier(&self.session)?;
        if !cfg!(feature = "llm-provider")
            || self.token_sha256 == [0; 32]
            || self.token_sha256 == gateway.config.token_sha256
            || gateway.provider_oauth_enabled
        {
            return Err(Error::Invalid(
                "HTTP credential or delegated identity profile",
            ));
        }
        Ok(())
    }
}
#[derive(Deserialize)]
struct File {
    gateway: Option<Gateway>,
}
#[derive(Deserialize)]
struct Gateway {
    http: Option<Settings>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    listen: SocketAddr,
    session: String,
    token_env: String,
}
pub(crate) async fn load() -> Result<Option<(tokio::net::TcpListener, HttpProfile)>> {
    let configured = std::env::var_os("WEAVER_CONFIG");
    let path = configured.clone().unwrap_or_else(|| "weaver.toml".into());
    let file = match tokio::fs::File::open(path).await {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound && configured.is_none() => {
            return Ok(None);
        }
        Err(_) => return Err(Error::Invalid("weaver.toml unavailable")),
    };
    let mut bytes = Vec::new();
    file.take(65_537)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| Error::Invalid("weaver.toml read"))?;
    if bytes.len() > 65_536 {
        return Err(Error::Invalid("weaver.toml bound"));
    }
    let parsed: File = toml::from_str(
        std::str::from_utf8(&bytes).map_err(|_| Error::Invalid("weaver.toml encoding"))?,
    )
    .map_err(|_| Error::Invalid("weaver.toml configuration"))?;
    let Some(settings) = parsed.gateway.and_then(|gateway| gateway.http) else {
        return Ok(None);
    };
    if !settings.listen.ip().is_loopback()
        || settings.token_env.is_empty()
        || settings.token_env.len() > 128
    {
        return Err(Error::Invalid("HTTP loopback or credential reference"));
    }
    weaver_contracts::identifier(&settings.session)?;
    let token = zeroize::Zeroizing::new(
        std::env::var(&settings.token_env)
            .map_err(|_| Error::Invalid("HTTP credential unavailable"))?,
    );
    if !(16..=256).contains(&token.len())
        || !token.is_ascii()
        || token.chars().any(char::is_whitespace)
    {
        return Err(Error::Invalid("HTTP credential bound"));
    }
    let profile = HttpProfile {
        session: settings.session,
        token_sha256: Sha256::digest(token.as_bytes()).into(),
    };
    let listener = tokio::net::TcpListener::bind(settings.listen)
        .await
        .map_err(|_| Error::Invalid("HTTP listener"))?;
    Ok(Some((listener, profile)))
}
