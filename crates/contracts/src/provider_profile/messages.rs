// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Text message roles and fields, without implicit tool or multimodal authority.
use crate::{Error, Result};
use serde_json::Value;

pub(super) fn validate(value: Option<&Value>, limit: u64, anthropic: bool) -> Result<u64> {
    let messages = value
        .and_then(Value::as_array)
        .filter(|v| !v.is_empty() && v.len() as u64 <= limit)
        .ok_or(Error::Invalid("profile messages"))?;
    for message in messages {
        let fields = message
            .as_object()
            .ok_or(Error::Invalid("text message object"))?;
        if anthropic
            && (fields.contains_key("name")
                || !matches!(
                    message.get("role").and_then(Value::as_str),
                    Some("user" | "assistant")
                ))
        {
            return Err(Error::Invalid("unregistered Anthropic message semantics"));
        }
        if fields
            .keys()
            .any(|k| !matches!(k.as_str(), "role" | "content" | "name"))
            || !matches!(
                message.get("role").and_then(Value::as_str),
                Some("system" | "developer" | "user" | "assistant")
            )
            || message.get("content").and_then(Value::as_str).is_none()
            || message
                .get("name")
                .is_some_and(|v| v.as_str().is_none_or(|s| s.is_empty() || s.len() > 64))
        {
            return Err(Error::Invalid("unregistered message semantics"));
        }
    }
    Ok(messages.len() as u64)
}
