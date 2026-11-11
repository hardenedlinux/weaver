// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Redacted error boundary for direct model calls.

/// Safe-to-report direct-client failures. Provider bodies and credentials are private.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The supplied endpoint or credential is invalid.
    #[error("invalid model client configuration")]
    Configuration,
    /// The credential requires a new login or a grant could not be activated.
    #[error("model authentication requires authorization")]
    Authentication,
    /// Local credentials were removed but supplier revocation was not confirmed.
    #[error("local credentials cleared, remote revocation unconfirmed")]
    RevocationUnconfirmed,
    /// The request cannot be represented by this provider.
    #[error("unsupported provider request: {0}")]
    Request(&'static str),
    /// The provider did not complete the HTTP exchange.
    #[error("provider transport failed")]
    Transport,
    /// The caller's configured HTTP deadline elapsed.
    #[error("provider request timed out")]
    Timeout,
    /// The provider reported rate limiting.
    #[error("provider rate limited the request")]
    RateLimited {
        /// Retry delay if the provider supplied integer seconds.
        retry_after_seconds: Option<u64>,
    },
    /// The provider refused or filtered the requested output.
    #[error("provider refused the requested output")]
    Refused,
    /// The model's context limit was exceeded.
    #[error("provider context limit exceeded")]
    ContextLength,
    /// The provider reported temporary unavailability.
    #[error("provider temporarily unavailable")]
    UpstreamUnavailable {
        /// HTTP status when the failure was reported before streaming.
        status: Option<u16>,
    },
    /// The provider returned an unsuccessful HTTP response.
    #[error("provider returned HTTP {0}")]
    Status(u16),
    /// The provider response violated the expected protocol.
    #[error("invalid provider response")]
    Response,
    /// The provider exceeded the configured response byte limit.
    #[error("provider response exceeded its byte limit")]
    Limit,
}

impl Error {
    pub(crate) fn provider_event(error: &serde_json::Value) -> Option<Self> {
        let code = error["code"].as_str();
        let kind = error["type"].as_str();
        if code == Some("context_length_exceeded")
            || (kind == Some("invalid_request_error")
                && error["message"]
                    .as_str()
                    .is_some_and(|message| message.starts_with("prompt is too long")))
        {
            return Some(Self::ContextLength);
        }
        match (code, kind) {
            (Some("rate_limit_exceeded"), _) | (_, Some("rate_limit_error")) => {
                Some(Self::RateLimited {
                    retry_after_seconds: None,
                })
            }
            (Some("server_error"), _)
            | (_, Some("overloaded_error" | "api_error" | "timeout_error")) => {
                Some(Self::UpstreamUnavailable { status: None })
            }
            _ => None,
        }
    }
}

pub(crate) fn refusal_reason(reason: &str) -> bool {
    matches!(reason, "refusal" | "content_filter")
}
