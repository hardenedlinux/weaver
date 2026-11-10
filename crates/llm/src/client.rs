// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Pooled HTTP transport and bounded response reads.

use crate::{Completion, EmbeddingRequest, Embeddings, Error, Protocol, Request, TurnStream};
use bytes::{Bytes, BytesMut};
use reqwest::{
    Response, Url,
    header::{AUTHORIZATION, CONTENT_TYPE, HeaderValue},
};
use std::time::Duration;

/// Exact upstream URL and its wire protocol.
#[derive(Clone)]
pub struct Endpoint {
    url: Url,
    protocol: Protocol,
}

impl Endpoint {
    /// Accept HTTPS, or HTTP on a loopback host for local providers.
    ///
    /// # Errors
    /// Returns an error for an invalid URL, user information or fragment.
    pub fn new(protocol: Protocol, url: &str) -> Result<Self, Error> {
        let url = Url::parse(url).map_err(|_| Error::Configuration)?;
        let loopback = url.host_str().is_some_and(|host| {
            host == "localhost"
                || host
                    .trim_matches(['[', ']'])
                    .parse::<std::net::IpAddr>()
                    .is_ok_and(|ip| ip.is_loopback())
        });
        if !(url.scheme() == "https" || (url.scheme() == "http" && loopback))
            || !url.has_host()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err(Error::Configuration);
        }
        Ok(Self { url, protocol })
    }
}

/// A reusable client with one connection pool and a fixed exchange budget.
#[derive(Clone, Debug)]
pub struct Client {
    http: reqwest::Client,
    response_limit: usize,
}

impl Client {
    /// Create a direct client. Deadlines include reading the response body.
    ///
    /// # Errors
    /// Returns an error if limits are zero or the HTTP client cannot initialize.
    pub fn new(timeout: Duration, response_limit: usize) -> Result<Self, Error> {
        if timeout.is_zero() || response_limit == 0 {
            return Err(Error::Configuration);
        }
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .no_proxy()
            .build()
            .map_err(|_| Error::Configuration)?;
        Ok(Self {
            http,
            response_limit,
        })
    }

    /// Send a completion and decode the bounded assistant result.
    ///
    /// # Errors
    /// Returns an error for invalid input or a failed provider exchange.
    pub async fn complete(
        &self,
        endpoint: &Endpoint,
        credential: &str,
        request: &Request<'_>,
    ) -> Result<Completion, Error> {
        let response = self
            .send(
                endpoint,
                credential,
                request.encode(endpoint.protocol, false)?,
                false,
            )
            .await?;
        let completion = Completion::decode(endpoint.protocol, &response.collect().await?)?;
        if request.options.tools.is_empty()
            && completion
                .choices
                .iter()
                .any(|choice| !choice.message.tool_calls.is_empty())
        {
            return Err(Error::Response);
        }
        Ok(completion)
    }

    /// Send a batch to the configured OpenAI-compatible embeddings URL.
    ///
    /// # Errors
    /// Returns an error for unsupported protocols, invalid input, a failed
    /// exchange, or a response without exactly one vector per input.
    pub async fn embed(
        &self,
        endpoint: &Endpoint,
        credential: &str,
        request: &EmbeddingRequest<'_>,
    ) -> Result<Embeddings, Error> {
        if endpoint.protocol != Protocol::OpenAi {
            return Err(Error::Request(
                "embeddings require an OpenAI-compatible endpoint",
            ));
        }
        let (body, count) = request.encode()?;
        let response = self.send(endpoint, credential, body, false).await?;
        Embeddings::decode(&response.collect().await?, count, request.dimensions)
    }

    /// Open a provider-native SSE response without buffering the full stream.
    ///
    /// # Errors
    /// Returns an error for invalid input, unsuccessful HTTP or a non-SSE response.
    pub async fn stream(
        &self,
        endpoint: &Endpoint,
        credential: &str,
        request: &Request<'_>,
    ) -> Result<EventStream, Error> {
        let stream = self
            .send(
                endpoint,
                credential,
                request.encode(endpoint.protocol, true)?,
                true,
            )
            .await?;
        let mime = stream
            .response
            .as_ref()
            .and_then(|response| response.headers().get(CONTENT_TYPE))
            .and_then(|header| header.to_str().ok())
            .and_then(|header| header.split(';').next());
        if !mime.is_some_and(|value| value.trim().eq_ignore_ascii_case("text/event-stream")) {
            return Err(Error::Response);
        }
        Ok(stream)
    }

    /// Open a typed text and tool-call stream for one assistant turn.
    ///
    /// # Errors
    /// Returns an error on invalid input or failure to establish the SSE exchange.
    pub async fn stream_turn(
        &self,
        endpoint: &Endpoint,
        credential: &str,
        request: &Request<'_>,
    ) -> Result<TurnStream, Error> {
        let body = self.stream(endpoint, credential, request).await?;
        Ok(TurnStream::new(
            body,
            endpoint.protocol,
            self.response_limit,
        ))
    }

    async fn send(
        &self,
        endpoint: &Endpoint,
        credential: &str,
        body: Vec<u8>,
        stream: bool,
    ) -> Result<EventStream, Error> {
        if credential.trim().is_empty() {
            return Err(Error::Configuration);
        }
        let mut builder = self
            .http
            .post(endpoint.url.clone())
            .header(CONTENT_TYPE, "application/json")
            .header(
                "accept",
                if stream {
                    "text/event-stream"
                } else {
                    "application/json"
                },
            )
            .body(body);
        let (name, value) = match endpoint.protocol {
            Protocol::OpenAi | Protocol::OpenAiResponses => {
                (AUTHORIZATION, format!("Bearer {credential}"))
            }
            Protocol::Anthropic => {
                builder = builder.header("anthropic-version", "2023-06-01");
                (
                    reqwest::header::HeaderName::from_static("x-api-key"),
                    credential.to_owned(),
                )
            }
        };
        let mut header = HeaderValue::from_str(&value).map_err(|_| Error::Configuration)?;
        header.set_sensitive(true);
        let response = builder
            .header(name, header)
            .send()
            .await
            .map_err(transport_error)?;
        if !response.status().is_success() {
            return Err(provider_failure(response, self.response_limit).await);
        }
        if response
            .content_length()
            .is_some_and(|length| length > self.response_limit as u64)
        {
            return Err(Error::Limit);
        }
        Ok(EventStream {
            response: Some(response),
            remaining: self.response_limit,
        })
    }
}

/// Bounded provider-native SSE bytes. A chunk is not an SSE record.
pub struct EventStream {
    response: Option<Response>,
    remaining: usize,
}

impl EventStream {
    async fn collect(mut self) -> Result<BytesMut, Error> {
        let mut body = BytesMut::new();
        while let Some(chunk) = self.next_chunk().await? {
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    }

    /// Read the next HTTP body chunk. Dropping this object cancels the body.
    ///
    /// # Errors
    /// Returns an error on a transport failure, timeout or byte-limit breach.
    pub async fn next_chunk(&mut self) -> Result<Option<Bytes>, Error> {
        let Some(response) = &mut self.response else {
            return Ok(None);
        };
        match response.chunk().await {
            Ok(Some(bytes)) if bytes.len() <= self.remaining => {
                self.remaining -= bytes.len();
                Ok(Some(bytes))
            }
            result => {
                self.response = None;
                match result {
                    Ok(None) => Ok(None),
                    Ok(Some(_)) => Err(Error::Limit),
                    Err(error) => Err(transport_error(error)),
                }
            }
        }
    }
}

fn transport_error(error: reqwest::Error) -> Error {
    if error.is_timeout() {
        Error::Timeout
    } else {
        Error::Transport
    }
}

async fn provider_failure(response: Response, response_limit: usize) -> Error {
    let status = response.status().as_u16();
    if status == 429 {
        let retry_after_seconds = response
            .headers()
            .get("retry-after")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.trim().parse().ok());
        return Error::RateLimited {
            retry_after_seconds,
        };
    }
    if matches!(status, 500 | 502 | 503 | 504 | 529) {
        return Error::UpstreamUnavailable {
            status: Some(status),
        };
    }
    if status == 400 {
        let bounded = EventStream {
            response: Some(response),
            remaining: response_limit.min(16 * 1024),
        };
        if let Ok(body) = bounded.collect().await
            && let Ok(payload) = serde_json::from_slice::<serde_json::Value>(&body)
            && let Some(Error::ContextLength) = Error::provider_event(&payload["error"])
        {
            return Error::ContextLength;
        }
    }
    Error::Status(status)
}
