// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Versioned rich observations; construction never grants send or tool authority.
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[path = "provider_turn_observation.rs"]
mod observation;
pub use observation::{
    ProviderTurnBlockKind, ProviderTurnControl, ProviderTurnItemKind, ProviderTurnMetadata,
    ProviderTurnPosition,
};

/// Maximum encoded rich observation, before queue reservation or publication.
pub const MAX_PROVIDER_TURN_BYTES: usize = 65_536;

/// One rich event carried separately from the legacy text field.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderTurnEvent {
    pub version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub metadata: Option<ProviderTurnMetadata>,
    pub payload: ProviderTurnPayload,
}

/// Complete tools and continuation blocks appear only at the terminal boundary.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProviderTurnPayload {
    Control,
    Text {
        text: String,
    },
    Thinking {
        text: String,
    },
    Finished {
        reason: String,
        identity: Option<ProviderTurnIdentity>,
        usage: Option<ProviderTurnUsage>,
        tool_calls: Vec<ProviderToolCall>,
        responses_output: Option<Vec<Value>>,
        anthropic_output: Option<Vec<Value>>,
    },
}

/// Provider-reported response identity, never an authenticated caller identity.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderTurnIdentity {
    pub id: String,
    pub model: String,
}

/// Reported usage; settlement still belongs to the existing metering owner.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderTurnUsage {
    /// Provider-reported input: inclusive for OpenAI, ordinary input for Claude.
    pub input_tokens: u64,
    pub output_tokens: u64,
    /// Disjoint categories for this draft rich contract; absent remains unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub categories: Option<ProviderTokenCategories>,
}

/// Normalized disjoint usage, committed with the complete released observation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderTokenCategories {
    pub ordinary_input: u64,
    pub cache_read_input: u64,
    pub cache_write_input: u64,
    pub output: u64,
}

impl ProviderTurnUsage {
    fn consistent(&self) -> bool {
        if self.input_tokens.checked_add(self.output_tokens).is_none() {
            return false;
        }
        let Some(c) = &self.categories else {
            return true;
        };
        let input = c
            .ordinary_input
            .checked_add(c.cache_read_input)
            .and_then(|n| n.checked_add(c.cache_write_input));
        input.is_some_and(|n| {
            n.checked_add(c.output).is_some()
                && (self.input_tokens == n || self.input_tokens == c.ordinary_input)
                && self.output_tokens == c.output
        })
    }
}

/// Complete function call observation; the Harness separately authorizes execution.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

impl std::fmt::Debug for ProviderTurnPayload {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Control => f.write_str("Control"),
            Self::Text { text } => f.debug_struct("Text").field("bytes", &text.len()).finish(),
            Self::Thinking { text } => f
                .debug_struct("Thinking")
                .field("bytes", &text.len())
                .finish(),
            Self::Finished {
                tool_calls,
                responses_output,
                anthropic_output,
                ..
            } => f
                .debug_struct("Finished")
                .field("tool_count", &tool_calls.len())
                .field("responses_output", &responses_output.is_some())
                .field("anthropic_output", &anthropic_output.is_some())
                .finish_non_exhaustive(),
        }
    }
}

impl std::fmt::Debug for ProviderToolCall {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderToolCall").finish_non_exhaustive()
    }
}

impl ProviderTurnEvent {
    /// Encodes a bounded observation. This does not validate a provider transcript.
    pub fn encode(&self) -> Result<Vec<u8>> {
        self.validate()?;
        let bytes = serde_json::to_vec(self)?;
        if bytes.len() > MAX_PROVIDER_TURN_BYTES {
            return Err(Error::Invalid("provider turn size"));
        }
        Ok(bytes)
    }

    /// Decodes a bounded, duplicate-key-free versioned observation.
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        let event: Self = crate::decode_bounded(bytes, MAX_PROVIDER_TURN_BYTES)?;
        event.validate()?;
        Ok(event)
    }

    /// Identifies a terminal payload without granting permission to publish it.
    pub fn is_terminal(&self) -> bool {
        matches!(self.payload, ProviderTurnPayload::Finished { .. })
    }

    fn validate(&self) -> Result<()> {
        if self.version != 1 {
            return Err(Error::Invalid("provider turn version"));
        }
        if self.metadata.as_ref().is_some_and(|m| !m.valid())
            || (matches!(self.payload, ProviderTurnPayload::Control) && self.metadata.is_none())
        {
            return Err(Error::Invalid("provider turn coordinates"));
        }
        if let ProviderTurnPayload::Finished {
            reason,
            identity,
            usage,
            tool_calls,
            responses_output,
            anthropic_output,
        } = &self.payload
        {
            let bounded = |s: &str| !s.is_empty() && s.len() <= 1024;
            if !bounded(reason)
                || identity
                    .as_ref()
                    .is_some_and(|id| !bounded(&id.id) || !bounded(&id.model))
                || usage.as_ref().is_some_and(|u| !u.consistent())
                || tool_calls.len() > 64
                || (responses_output.is_some() && anthropic_output.is_some())
                || (matches!(reason.as_str(), "tool_calls" | "tool_use") && tool_calls.is_empty())
                || (!tool_calls.is_empty()
                    && !matches!(reason.as_str(), "tool_calls" | "tool_use" | "completed"))
            {
                return Err(Error::Invalid("provider terminal observation"));
            }
            let mut ids = std::collections::BTreeSet::new();
            if tool_calls.iter().any(|call| {
                !bounded(&call.id)
                    || !bounded(&call.name)
                    || !call.arguments.is_object()
                    || !ids.insert(&call.id)
            }) {
                return Err(Error::Invalid("provider terminal tools"));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "../tests/unit/provider_turn.rs"]
mod tests;
