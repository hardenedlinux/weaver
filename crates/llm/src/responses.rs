// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! OpenAI Responses with caller-owned history and encrypted reasoning replay.

use std::{collections::HashSet, fmt};

use serde::{Deserialize, Serialize, Serializer, ser::SerializeSeq};
use serde_json::{Value, json};

use crate::{
    Completion, CompletionChoice, Error, Message, Request, Role, ToolCall, TurnEvent, TurnIdentity,
    Usage,
};

/// Provider output kept with the corresponding assistant message for replay.
#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct ResponsesOutput(Vec<Value>);

impl fmt::Debug for ResponsesOutput {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ResponsesOutput")
            .field("item_count", &self.0.len())
            .finish()
    }
}

pub(crate) fn encode(
    request: &Request<'_>,
    stream: bool,
    tool_choice: Option<Value>,
    response_format: Option<Value>,
) -> Result<Vec<u8>, Error> {
    let options = request.options;
    if options.seed.is_some() || options.stop.is_some() {
        return Err(Error::Request("Responses seed and stop options"));
    }

    if request
        .messages
        .iter()
        .any(|message| message.name.is_some() || message.role == Role::Function)
    {
        return Err(Error::Request(
            "Responses named messages and legacy function role",
        ));
    }
    let tools: Vec<_> = options
        .tools
        .iter()
        .map(|tool| WireTool {
            kind: "function",
            name: &tool.name,
            description: &tool.description,
            parameters: &tool.parameters,
            strict: false,
        })
        .collect();
    let payload = WireRequest {
        model: request.model,
        input: WireInput(request.messages),
        stream,
        store: false,
        include: ["reasoning.encrypted_content"],
        max_output_tokens: options.max_tokens,
        temperature: options.temperature,
        top_p: options.top_p,
        safety_identifier: options.user.as_deref(),
        tools,
        tool_choice,
        text: response_format.map(|format| json!({"format": format})),
    };
    serde_json::to_vec(&payload).map_err(|_| Error::Request("invalid Responses request"))
}

#[derive(Serialize)]
struct WireRequest<'a> {
    model: &'a str,
    input: WireInput<'a>,
    stream: bool,
    store: bool,
    include: [&'static str; 1],
    #[serde(skip_serializing_if = "Option::is_none")]
    max_output_tokens: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    top_p: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    safety_identifier: Option<&'a str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tools: Vec<WireTool<'a>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_choice: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<Value>,
}

#[derive(Serialize)]
struct WireTool<'a> {
    #[serde(rename = "type")]
    kind: &'static str,
    name: &'a str,
    description: &'a str,
    parameters: &'a Value,
    strict: bool,
}

struct WireInput<'a>(&'a [Message]);

impl Serialize for WireInput<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut sequence = serializer.serialize_seq(None)?;
        for message in self.0 {
            write_input_message(&mut sequence, message)?;
        }
        sequence.end()
    }
}

fn write_input_message<S: SerializeSeq>(
    sequence: &mut S,
    message: &Message,
) -> Result<(), S::Error> {
    if let Some(output) = &message.responses_output {
        for item in &output.0 {
            sequence.serialize_element(item)?;
        }
        return Ok(());
    }
    if message.role == Role::Tool {
        return sequence.serialize_element(&json!({
            "type": "function_call_output", "call_id": message.tool_call_id,
            "output": message.content,
        }));
    }
    if !message.images.is_empty() {
        let content = crate::images::content_blocks(
            &message.content,
            &message.images,
            crate::Protocol::OpenAiResponses,
        );
        return sequence.serialize_element(&json!({"role":message.role,"content":content}));
    }
    if !message.content.is_empty() || message.tool_calls.is_empty() {
        #[derive(Serialize)]
        struct Text<'a> {
            role: Role,
            content: &'a str,
        }
        sequence.serialize_element(&Text {
            role: message.role,
            content: &message.content,
        })?;
    }
    for call in &message.tool_calls {
        sequence.serialize_element(&json!({
            "type": "function_call", "call_id": call.id, "name": call.name,
            "arguments": call.arguments.to_string(),
        }))?;
    }
    Ok(())
}

pub(crate) fn event(mut event: Value) -> Result<Option<TurnEvent>, Error> {
    match event["type"].as_str().ok_or(Error::Response)? {
        "response.output_text.delta" => Ok(Some(TurnEvent::Text(
            event["delta"].as_str().ok_or(Error::Response)?.to_owned(),
        ))),
        "response.completed" => {
            let response = event["response"].take();
            let final_response = finish(response)?;
            let reason = if final_response.calls.is_empty() {
                "stop"
            } else {
                "tool_calls"
            };
            Ok(Some(TurnEvent::Finished {
                reason: reason.into(),
                identity: Some(TurnIdentity {
                    id: final_response.id,
                    model: final_response.model,
                }),
                usage: final_response.usage,
                tool_calls: final_response.calls,
                responses_output: Some(ResponsesOutput(final_response.output)),
            }))
        }
        "response.failed" => {
            Err(Error::provider_event(&event["response"]["error"]).unwrap_or(Error::Response))
        }
        "error" => Err(Error::provider_event(&event).unwrap_or(Error::Response)),
        "response.refusal.delta" | "response.refusal.done" => Err(Error::Refused),
        "response.incomplete" => Err(incomplete_error(&event["response"])),
        _ => Ok(None),
    }
}

struct FinalResponse {
    id: String,
    model: String,
    output: Vec<Value>,
    calls: Vec<ToolCall>,
    usage: Option<Usage>,
}

fn finish(mut response: Value) -> Result<FinalResponse, Error> {
    if response["status"].as_str() != Some("completed") {
        return Err(incomplete_error(&response));
    }
    let Value::Array(output) = response["output"].take() else {
        return Err(Error::Response);
    };
    let mut calls = Vec::new();
    let mut ids = HashSet::new();
    for item in &output {
        match item["type"].as_str() {
            Some("function_call") => {
                let id = string(&item["call_id"])?;
                if item["status"]
                    .as_str()
                    .is_some_and(|status| status != "completed")
                    || !ids.insert(id)
                {
                    return Err(Error::Response);
                }
                let arguments = serde_json::from_str::<Value>(string(&item["arguments"])?)
                    .ok()
                    .filter(Value::is_object)
                    .ok_or(Error::Response)?;
                calls.push(ToolCall {
                    id: id.into(),
                    name: string(&item["name"])?.into(),
                    arguments,
                });
            }
            Some("message") => {
                if item["content"]
                    .as_array()
                    .is_some_and(|parts| parts.iter().any(|part| part["type"] == "refusal"))
                {
                    return Err(Error::Refused);
                }
            }
            Some("reasoning") => {}
            _ => return Err(Error::Response),
        }
    }
    let usage = serde_json::from_value(response["usage"].take()).map_err(|_| Error::Response)?;
    Ok(FinalResponse {
        id: string(&response["id"])?.into(),
        model: string(&response["model"])?.into(),
        output,
        calls,
        usage,
    })
}

pub(crate) fn complete(bytes: &[u8]) -> Result<Completion, Error> {
    let response = finish(serde_json::from_slice(bytes).map_err(|_| Error::Response)?)?;
    let reason = if response.calls.is_empty() {
        "stop"
    } else {
        "tool_calls"
    };
    let mut text = String::new();
    for item in response
        .output
        .iter()
        .filter(|item| item["type"] == "message")
    {
        append_text(item, &mut text)?;
    }
    Ok(Completion {
        id: response.id,
        model: response.model,
        choices: vec![CompletionChoice {
            index: 0,
            message: Message {
                role: Role::Assistant,
                content: text,
                images: Vec::new(),
                name: None,
                tool_call_id: None,
                tool_calls: response.calls,
                responses_output: Some(ResponsesOutput(response.output)),
            },
            finish_reason: Some(reason.into()),
        }],
        usage: response.usage,
    })
}

fn incomplete_error(response: &Value) -> Error {
    if response["incomplete_details"]["reason"]
        .as_str()
        .is_some_and(crate::error::refusal_reason)
    {
        Error::Refused
    } else {
        Error::Response
    }
}

fn append_text(message: &Value, text: &mut String) -> Result<(), Error> {
    for part in message["content"].as_array().ok_or(Error::Response)? {
        if part["type"] != "output_text" {
            return Err(Error::Response);
        }
        text.push_str(part["text"].as_str().ok_or(Error::Response)?);
    }
    Ok(())
}

fn string(value: &Value) -> Result<&str, Error> {
    value
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or(Error::Response)
}
