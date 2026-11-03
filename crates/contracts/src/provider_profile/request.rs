// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Closed request interpretation for the registered text/SSE protocol.
use super::{ProviderProfile, ProviderRequestFacts, messages, sampling};
use crate::{Error, Result};

impl ProviderProfile {
    /// Interpret only implemented text/SSE fields. Exact request bytes are never rewritten.
    pub fn request_facts(&self, source: &str) -> Result<ProviderRequestFacts> {
        self.validate()?;
        if source.len() as u64 > self.max_body_bytes {
            return Err(Error::Invalid("profile body limit"));
        }
        let body: serde_json::Value = crate::decode(source.as_bytes())?;
        let object = body
            .as_object()
            .ok_or(Error::Invalid("provider request object"))?;
        for key in object.keys() {
            if !matches!(
                key.as_str(),
                "model"
                    | "stream"
                    | "messages"
                    | "max_completion_tokens"
                    | "max_tokens"
                    | "n"
                    | "temperature"
                    | "top_p"
                    | "frequency_penalty"
                    | "presence_penalty"
                    | "seed"
                    | "stop"
                    | "stream_options"
                    | "user"
                    | "response_format"
            ) {
                return Err(Error::Invalid("unregistered provider request field"));
            }
        }
        let model = body
            .get("model")
            .and_then(|v| v.as_str())
            .ok_or(Error::Invalid("provider model"))?;
        crate::identifier(model)?;
        if body.get("stream").and_then(|v| v.as_bool()) != Some(true)
            || body.get("n").is_some_and(|v| v.as_u64() != Some(1))
        {
            return Err(Error::Invalid("provider response profile"));
        }
        let tokens = match (body.get("max_completion_tokens"), body.get("max_tokens")) {
            (Some(v), None) | (None, Some(v)) => v.as_u64(),
            _ => None,
        }
        .filter(|n| *n > 0 && *n <= self.max_output_tokens)
        .ok_or(Error::Invalid("profile output token limit"))?;
        let messages = messages::validate(body.get("messages"), self.max_messages)?;
        sampling::validate(object)?;
        Ok(ProviderRequestFacts {
            model: model.into(),
            output_token_limit: tokens,
            message_count: messages,
        })
    }
}
