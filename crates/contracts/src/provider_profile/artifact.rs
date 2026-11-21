// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Validated source artifacts and domain-separated `ProviderProfile` commitments.
use crate::{Error, MAX_BODY_BYTES, Result, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// Closed implementation protocol; other protocols require their own semantic owner.
pub const CHAT_TEXT_SSE: &str = "openai.chat-text-sse.v1";
/// Anthropic Messages text streaming with the validated SSE event sequence.
pub const ANTHROPIC_MESSAGES_SSE: &str = "anthropic.messages-text-sse.v1";
/// Tool-capable OpenAI Chat turns, distinct from the closed text profile.
pub const CHAT_TURN_SSE: &str = "openai.chat-turn-sse.v1";
/// Stateless OpenAI Responses turns with opaque continuation preservation.
pub const RESPONSES_TURN_SSE: &str = "openai.responses-turn-sse.v1";
/// Tool-capable Anthropic Messages turns with ordered continuation blocks.
pub const ANTHROPIC_TURN_SSE: &str = "anthropic.messages-turn-sse.v1";

/// Supported request and stream adapters selected from a validated profile.
#[derive(Clone, Copy)]
pub enum ProviderProtocol {
    OpenAi,
    Anthropic,
    OpenAiTurn,
    OpenAiResponses,
    AnthropicTurn,
}

impl ProviderProtocol {
    /// Whether the provider uses Anthropic Messages authentication and routing.
    pub fn is_anthropic(self) -> bool {
        matches!(self, Self::Anthropic | Self::AnthropicTurn)
    }

    /// Whether the profile requires the versioned rich-event contract.
    pub fn is_rich(self) -> bool {
        matches!(
            self,
            Self::OpenAiTurn | Self::OpenAiResponses | Self::AnthropicTurn
        )
    }
}

/// Authenticated source artifact, registered atomically with its original task.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderProfile {
    pub id: String,
    pub protocol: String,
    pub max_output_tokens: u64,
    pub max_messages: u64,
    pub max_body_bytes: u64,
}

/// Validated data facts, not a send capability or a budget settlement receipt.
pub struct ProviderRequestFacts {
    pub model: String,
    pub output_token_limit: u64,
    pub message_count: u64,
}

impl ProviderProfile {
    pub fn validate(&self) -> Result<()> {
        identifier(&self.id)?;
        self.adapter()?;
        if !(1..=4096).contains(&self.max_output_tokens)
            || !(1..=64).contains(&self.max_messages)
            || !(1..=MAX_BODY_BYTES as u64).contains(&self.max_body_bytes)
        {
            return Err(Error::Invalid("provider profile"));
        }
        Ok(())
    }
    pub fn adapter(&self) -> Result<ProviderProtocol> {
        match self.protocol.as_str() {
            CHAT_TEXT_SSE => Ok(ProviderProtocol::OpenAi),
            ANTHROPIC_MESSAGES_SSE => Ok(ProviderProtocol::Anthropic),
            CHAT_TURN_SSE => Ok(ProviderProtocol::OpenAiTurn),
            RESPONSES_TURN_SSE => Ok(ProviderProtocol::OpenAiResponses),
            ANTHROPIC_TURN_SSE => Ok(ProviderProtocol::AnthropicTurn),
            _ => Err(Error::Invalid("provider protocol")),
        }
    }
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.provider-profile.v1",
            &self.id,
            &self.protocol,
            self.max_output_tokens,
            self.max_messages,
            self.max_body_bytes,
        ))?))
    }
}
