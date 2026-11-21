// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source-approved rich request bounds. No tool execution authority is inferred.
use super::{ProviderProfile, ProviderProtocol, ProviderRequestFacts};
use crate::{Error, Result};
use serde_json::Value;

pub(super) fn facts(profile: &ProviderProfile, body: &Value) -> Result<ProviderRequestFacts> {
    let protocol = profile.adapter()?;
    let fields = body
        .as_object()
        .ok_or(Error::Invalid("turn request object"))?;
    let responses = matches!(protocol, ProviderProtocol::OpenAiResponses);
    for key in fields.keys() {
        let common = matches!(
            key.as_str(),
            "model" | "stream" | "tools" | "tool_choice" | "temperature" | "top_p"
        );
        let admitted = if responses {
            matches!(
                key.as_str(),
                "input"
                    | "store"
                    | "include"
                    | "max_output_tokens"
                    | "text"
                    | "safety_identifier"
                    | "parallel_tool_calls"
            )
        } else if protocol.is_anthropic() {
            matches!(
                key.as_str(),
                "messages"
                    | "system"
                    | "max_tokens"
                    | "thinking"
                    | "output_config"
                    | "stop_sequences"
                    | "metadata"
                    | "top_k"
            )
        } else {
            matches!(
                key.as_str(),
                "messages"
                    | "max_tokens"
                    | "max_completion_tokens"
                    | "n"
                    | "stream_options"
                    | "response_format"
                    | "seed"
                    | "stop"
                    | "user"
                    | "frequency_penalty"
                    | "presence_penalty"
                    | "parallel_tool_calls"
            )
        };
        if !common && !admitted {
            return Err(Error::Invalid("unregistered turn request field"));
        }
    }
    let model = body["model"].as_str().ok_or(Error::Invalid("turn model"))?;
    crate::identifier(model)?;
    if body["stream"] != true || body.get("n").is_some_and(|n| n.as_u64() != Some(1)) {
        return Err(Error::Invalid("turn streaming profile"));
    }
    let caps = ["max_tokens", "max_completion_tokens", "max_output_tokens"];
    let present: Vec<_> = caps.iter().filter_map(|key| body.get(key)).collect();
    let tokens = match present.as_slice() {
        [value] => value
            .as_u64()
            .filter(|n| *n > 0 && *n <= profile.max_output_tokens),
        _ => None,
    }
    .ok_or(Error::Invalid("turn output token limit"))?;
    if responses && body.get("store") != Some(&Value::Bool(false)) {
        return Err(Error::Invalid("stateless Responses store=false required"));
    }
    let messages = body[if responses { "input" } else { "messages" }]
        .as_array()
        .filter(|m| !m.is_empty() && m.len() as u64 <= profile.max_messages)
        .ok_or(Error::Invalid("turn messages"))?;
    for message in messages {
        if !message.is_object() {
            return Err(Error::Invalid("turn message object"));
        }
        if responses && message.get("type").is_some_and(|kind| kind != "message") {
            match message["type"].as_str() {
                Some("function_call")
                    if nonempty(&message["call_id"])
                        && nonempty(&message["name"])
                        && message["arguments"].as_str().is_some_and(|args| {
                            crate::decode::<Value>(args.as_bytes()).is_ok_and(|v| v.is_object())
                        }) => {}
                Some("function_call_output")
                    if nonempty(&message["call_id"]) && message["output"].is_string() => {}
                Some("reasoning") if nonempty(&message["encrypted_content"]) => {}
                _ => return Err(Error::Invalid("Responses continuation item")),
            }
        } else {
            let role = message["role"]
                .as_str()
                .ok_or(Error::Invalid("turn message role"))?;
            let valid_role = if protocol.is_anthropic() {
                matches!(role, "user" | "assistant")
            } else {
                matches!(role, "system" | "developer" | "user" | "assistant" | "tool")
            };
            if !valid_role || (role == "tool" && !nonempty(&message["tool_call_id"])) {
                return Err(Error::Invalid("turn role or tool correlation"));
            }
            let content = &message["content"];
            if !(content.is_string()
                || content.is_array()
                || (role == "assistant" && content.is_null() && message["tool_calls"].is_array()))
            {
                return Err(Error::Invalid("turn message content"));
            }
        }
    }
    if let Some(tools) = body.get("tools") {
        let tools = tools
            .as_array()
            .filter(|t| t.len() <= 64)
            .ok_or(Error::Invalid("turn tools bound"))?;
        let mut names = std::collections::BTreeSet::new();
        for tool in tools {
            let function = if protocol.is_anthropic() {
                tool
            } else if tool["type"] == "function" {
                if responses { tool } else { &tool["function"] }
            } else {
                return Err(Error::Invalid("only Harness function tools admitted"));
            };
            let name = function["name"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 128)
                .ok_or(Error::Invalid("turn function name"))?;
            if !names.insert(name)
                || !function[if protocol.is_anthropic() {
                    "input_schema"
                } else {
                    "parameters"
                }]
                .is_object()
                || (protocol.is_anthropic()
                    && tool.get("type").is_some_and(|kind| kind != "custom"))
            {
                return Err(Error::Invalid("turn function schema or duplicate"));
            }
        }
    }
    super::sampling::validate(fields)?;
    Ok(ProviderRequestFacts {
        model: model.into(),
        output_token_limit: tokens,
        message_count: messages.len() as u64,
    })
}

fn nonempty(value: &Value) -> bool {
    value
        .as_str()
        .is_some_and(|s| !s.is_empty() && s.len() <= 1024)
}
