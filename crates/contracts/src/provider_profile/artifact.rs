//! Validated source artifacts and domain-separated `ProviderProfile` commitments.
use crate::{Error, MAX_BODY_BYTES, Result, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// Closed implementation protocol; other protocols require their own semantic owner.
pub const CHAT_TEXT_SSE: &str = "openai.chat-text-sse.v1";

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
        if self.protocol != CHAT_TEXT_SSE
            || !(1..=4096).contains(&self.max_output_tokens)
            || !(1..=64).contains(&self.max_messages)
            || !(1..=MAX_BODY_BYTES as u64).contains(&self.max_body_bytes)
        {
            return Err(Error::Invalid("provider profile"));
        }
        Ok(())
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
