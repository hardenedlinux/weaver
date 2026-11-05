// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Canonical HTTPS target binding and one bounded network attempt.
use reqwest::{Url, blocking::Client, redirect::Policy};
use std::{collections::BTreeMap, time::Duration};
use weaver_contracts::{Error, Proposal, Result};

/// Bounded final transport; raw send is private to this crate.
pub struct HttpsTransport {
    client: Client,
    credentials: BTreeMap<String, String>,
}

/// Status alone is not authenticated terminal usage and never releases a hold.
/// Observed response headers or an indeterminate request outcome.
#[derive(Debug)]
pub enum SendObservation {
    ResponseHeaders(u16),
    Indeterminate,
}

impl HttpsTransport {
    /// Construct a bounded client with redirects, proxy inheritance and retries disabled.
    pub fn new(credentials: BTreeMap<String, String>) -> Result<Self> {
        let client = Client::builder()
            .https_only(true)
            .no_proxy()
            .redirect(Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(3))
            .timeout(Duration::from_secs(10))
            .pool_max_idle_per_host(0)
            .build()
            .map_err(|_| Error::Invalid("HTTPS client"))?;
        Ok(Self {
            client,
            credentials,
        })
    }
    /// Require one canonical HTTPS destination without embedded credentials.
    pub fn validate_endpoint(endpoint: &str) -> Result<()> {
        let url = Url::parse(endpoint).map_err(|_| Error::Invalid("endpoint"))?;
        if url.scheme() != "https"
            || url.host_str().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
            || url.as_str() != endpoint
        {
            return Err(Error::Invalid("canonical HTTPS endpoint required"));
        }
        Ok(())
    }
    // Deliberately crate-private: callers must pass through durable consumption.
    pub(crate) fn send(&self, p: &Proposal) -> SendObservation {
        if Self::validate_endpoint(&p.endpoint).is_err() {
            return SendObservation::Indeterminate;
        }
        let mut request = self
            .client
            .post(&p.endpoint)
            .header("Content-Type", "application/json")
            .body(p.body.clone());
        if let Some(secret) = self.credentials.get(&p.target) {
            request = request.bearer_auth(secret);
        }
        match request.send() {
            Ok(response) => SendObservation::ResponseHeaders(response.status().as_u16()),
            Err(_) => SendObservation::Indeterminate,
        }
    }
}

#[cfg(test)]
#[path = "../../tests/unit/https_transport.rs"]
mod tests;
