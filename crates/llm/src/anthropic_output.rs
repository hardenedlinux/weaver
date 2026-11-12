// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Opaque Anthropic assistant output for lossless continuation.

use crate::{Error, Message, Role, ToolCall};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fmt;

/// Ordered provider content blocks, including signed or redacted thinking.
#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct AnthropicOutput(pub(crate) Vec<Value>);

impl fmt::Debug for AnthropicOutput {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AnthropicOutput")
            .field("block_count", &self.0.len())
            .finish()
    }
}

impl AnthropicOutput {
    pub(crate) fn parse(blocks: Vec<Value>) -> Result<(Self, String, Vec<ToolCall>), Error> {
        let (text, calls) = Self::extract(&blocks)?;
        Ok((Self(blocks), text, calls))
    }

    fn extract(blocks: &[Value]) -> Result<(String, Vec<ToolCall>), Error> {
        let mut text = String::new();
        let mut calls = Vec::new();
        for block in blocks {
            match block["type"].as_str() {
                Some("text") => text.push_str(block["text"].as_str().ok_or(Error::Response)?),
                Some("thinking")
                    if block["thinking"].is_string()
                        && (block.get("signature").is_none() || block["signature"].is_string()) => {
                }
                Some("redacted_thinking") if block["data"].is_string() => {}
                Some("tool_use") => {
                    let id = block["id"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .ok_or(Error::Response)?;
                    let name = block["name"]
                        .as_str()
                        .filter(|s| !s.is_empty())
                        .ok_or(Error::Response)?;
                    let arguments = block["input"].as_object().ok_or(Error::Response)?;
                    calls.push(ToolCall {
                        id: id.into(),
                        name: name.into(),
                        arguments: Value::Object(arguments.clone()),
                    });
                }
                _ => return Err(Error::Response),
            }
        }
        Ok((text, calls))
    }

    /// Check observed answer and thinking against the retained provider blocks.
    ///
    /// This checks consistency, not the authenticity of a provider signature.
    /// Redacted thinking remains opaque and is preserved in the continuation.
    pub fn matches_observed(&self, text: &str, thinking: &str) -> bool {
        let Ok((output_text, calls)) = Self::extract(&self.0) else {
            return false;
        };
        if output_text != text || !calls.is_empty() {
            return false;
        }
        let mut remaining = thinking;
        for block in &self.0 {
            if block["type"].as_str() == Some("thinking") {
                let Some(part) = block["thinking"].as_str() else {
                    return false;
                };
                let Some(rest) = remaining.strip_prefix(part) else {
                    return false;
                };
                remaining = rest;
            }
        }
        remaining.is_empty()
    }

    pub(crate) fn matches(&self, message: &Message) -> bool {
        if message.role != Role::Assistant || !message.images.is_empty() {
            return false;
        }
        match Self::extract(&self.0) {
            Ok((text, calls)) => text == message.content && calls == message.tool_calls,
            Err(_) => false,
        }
    }
}
