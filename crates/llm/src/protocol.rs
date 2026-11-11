// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Request and completion codecs for the supported upstream protocols.

use std::collections::HashSet;

use crate::{Error, ImageInput, images::content_blocks};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Wire protocol expected by the endpoint.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Protocol {
    /// OpenAI Chat Completions.
    OpenAi,
    /// OpenAI Responses.
    OpenAiResponses,
    /// Anthropic Messages.
    Anthropic,
}

/// Text message role.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// System instruction.
    System,
    /// Developer instruction.
    Developer,
    /// User turn.
    User,
    /// Assistant turn.
    Assistant,
    /// OpenAI tool result.
    Tool,
    /// Legacy OpenAI function result.
    Function,
}

/// One message in a text conversation.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Message {
    /// Message role.
    pub role: Role,
    /// Message text.
    pub content: String,
    /// Images following the text in a user message.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub images: Vec<ImageInput>,
    /// Optional sender name for OpenAI-compatible endpoints.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// The preceding tool-call ID for OpenAI tool results.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<String>,
    /// Function calls to preserve in the assistant's turn.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ToolCall>,
    /// Stateless OpenAI Responses output to replay for this assistant turn.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub responses_output: Option<crate::ResponsesOutput>,
}

/// A function the Harness offers to the model.
#[derive(Clone, Debug, Serialize)]
pub struct Tool {
    /// Provider-visible function name.
    pub name: String,
    /// Description of the function.
    pub description: String,
    /// JSON Schema for the arguments.
    pub parameters: Value,
}

/// A provider-assigned function call and its arguments.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ToolCall {
    /// Identifier used to correlate a tool result.
    pub id: String,
    /// Function name.
    pub name: String,
    /// Arguments as a JSON object.
    pub arguments: Value,
}

/// Select whether the model may or must call a declared function.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ToolChoice {
    /// Let the model decide whether to call a tool.
    Auto,
    /// Disable tool calls.
    None,
    /// Require a call to one of the declared tools.
    Required,
    /// Require a call to this declared function.
    Function(String),
}

impl ToolChoice {
    pub(crate) fn encode(&self, protocol: Protocol) -> Value {
        match (protocol, self) {
            (Protocol::Anthropic, Self::Auto) => json!({"type": "auto"}),
            (Protocol::Anthropic, Self::None) => json!({"type": "none"}),
            (Protocol::Anthropic, Self::Required) => json!({"type": "any"}),
            (Protocol::Anthropic, Self::Function(name)) => json!({"type": "tool", "name": name}),
            (Protocol::OpenAi, Self::Function(name)) => {
                json!({"type": "function", "function": {"name": name}})
            }
            (Protocol::OpenAiResponses, Self::Function(name)) => {
                json!({"type": "function", "name": name})
            }
            (_, Self::Auto) => json!("auto"),
            (_, Self::None) => json!("none"),
            (_, Self::Required) => json!("required"),
        }
    }
}

/// Provider-enforced format for assistant text.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ResponseFormat {
    /// Require a JSON object on OpenAI-compatible APIs.
    JsonObject,
    /// Request strict adherence to a provider-supported JSON Schema.
    JsonSchema {
        /// Schema identifier on OpenAI-compatible APIs.
        name: String,
        /// Schema object supported by the selected provider and model.
        schema: Value,
    },
}

impl ResponseFormat {
    pub(crate) fn encode(&self, protocol: Protocol) -> Result<Value, Error> {
        match self {
            Self::JsonObject if protocol == Protocol::Anthropic => Err(Error::Request(
                "Anthropic JSON output requires a JSON Schema",
            )),
            Self::JsonObject => Ok(json!({"type": "json_object"})),
            Self::JsonSchema { name, schema } => {
                if !schema.is_object()
                    || name.is_empty()
                    || name.len() > 64
                    || !name
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
                {
                    return Err(Error::Request("invalid structured output schema or name"));
                }
                Ok(match protocol {
                    Protocol::OpenAi => json!({
                        "type": "json_schema",
                        "json_schema": {"name": name, "schema": schema, "strict": true},
                    }),
                    Protocol::OpenAiResponses => json!({
                        "type": "json_schema", "name": name, "schema": schema, "strict": true,
                    }),
                    Protocol::Anthropic => json!({"type": "json_schema", "schema": schema}),
                })
            }
        }
    }
}

/// Portable generation options. Unsupported provider options are rejected.
#[derive(Clone, Debug, Default, Serialize)]
pub struct Options {
    /// Functions available to the model in the current turn.
    #[serde(skip)]
    pub tools: Vec<Tool>,
    /// Explicit tool-selection policy. Omit to use the provider default.
    #[serde(skip)]
    pub tool_choice: Option<ToolChoice>,
    /// Explicit structured response format.
    #[serde(skip)]
    pub response_format: Option<ResponseFormat>,
    /// Request terminal usage on OpenAI-compatible streams that support it.
    #[serde(skip)]
    pub stream_usage: bool,
    /// Sampling temperature.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    /// Maximum generated tokens.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    /// Nucleus sampling probability.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f32>,
    /// Stop sequences.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop: Option<Vec<String>>,
    /// Optional OpenAI-compatible end-user identifier.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    /// Optional OpenAI-compatible sampling seed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub seed: Option<i32>,
}

/// Text completion input, borrowing the caller's conversation.
#[derive(Debug)]
pub struct Request<'a> {
    /// Exact provider model identifier.
    pub model: &'a str,
    /// Ordered conversation.
    pub messages: &'a [Message],
    /// Generation options.
    pub options: &'a Options,
}

impl Request<'_> {
    /// Encode this request for one provider.
    ///
    /// # Errors
    /// Returns an error for unsupported roles, options, or invalid inputs.
    pub fn encode(&self, protocol: Protocol, stream: bool) -> Result<Vec<u8>, Error> {
        if self.model.trim().is_empty()
            || self.messages.is_empty()
            || self.options.max_tokens == Some(0)
            || self
                .options
                .temperature
                .is_some_and(|value| !value.is_finite())
            || self.options.top_p.is_some_and(|value| !value.is_finite())
        {
            return Err(Error::Request(
                "invalid model, conversation or generation option",
            ));
        }
        if self
            .options
            .tools
            .iter()
            .any(|tool| tool.name.is_empty() || !tool.parameters.is_object())
            || self.messages.iter().any(|message| {
                ((!message.tool_calls.is_empty() || message.responses_output.is_some())
                    && message.role != Role::Assistant)
                    || (message.responses_output.is_some() && protocol != Protocol::OpenAiResponses)
                    || (message.role == Role::Tool
                        && message.tool_call_id.as_deref().is_none_or(str::is_empty))
                    || (message.role != Role::Tool && message.tool_call_id.is_some())
                    || message.tool_calls.iter().any(|call| {
                        call.id.is_empty() || call.name.is_empty() || !call.arguments.is_object()
                    })
            })
        {
            return Err(Error::Request("invalid tool definition, call or result"));
        }
        self.validate_images()?;
        let tool_choice = self.options.tool_choice.as_ref();
        match tool_choice {
            Some(ToolChoice::Required) if self.options.tools.is_empty() => {
                return Err(Error::Request("required tool choice needs declared tools"));
            }
            Some(ToolChoice::Function(name))
                if !self.options.tools.iter().any(|tool| &tool.name == name) =>
            {
                return Err(Error::Request("chosen function is not declared"));
            }
            _ => {}
        }
        let tool_choice = tool_choice.map(|choice| choice.encode(protocol));
        let response_format = self
            .options
            .response_format
            .as_ref()
            .map(|format| format.encode(protocol))
            .transpose()?;
        match protocol {
            Protocol::OpenAi => self.openai(stream, tool_choice, response_format),
            Protocol::Anthropic => self.anthropic(stream, tool_choice, response_format),
            Protocol::OpenAiResponses => {
                crate::responses::encode(self, stream, tool_choice, response_format)
            }
        }
    }

    fn validate_images(&self) -> Result<(), Error> {
        for message in self
            .messages
            .iter()
            .filter(|message| !message.images.is_empty())
        {
            if message.role != Role::User {
                return Err(Error::Request("images require a user message"));
            }
            for image in &message.images {
                image.validate()?;
            }
        }
        Ok(())
    }

    fn openai(
        &self,
        stream: bool,
        tool_choice: Option<Value>,
        response_format: Option<Value>,
    ) -> Result<Vec<u8>, Error> {
        #[derive(Serialize)]
        struct OpenAiRequest<'a> {
            model: &'a str,
            messages: Vec<OpenAiMessage<'a>>,
            stream: bool,
            #[serde(skip_serializing_if = "Option::is_none")]
            stream_options: Option<Value>,
            #[serde(skip_serializing_if = "Option::is_none")]
            tool_choice: Option<Value>,
            #[serde(skip_serializing_if = "Option::is_none")]
            response_format: Option<Value>,
            #[serde(skip_serializing_if = "Vec::is_empty")]
            tools: Vec<Value>,
            #[serde(flatten)]
            options: &'a Options,
        }
        serde_json::to_vec(&OpenAiRequest {
            model: self.model,
            messages: self.messages.iter().map(OpenAiMessage::from).collect(),
            tools: self
                .options
                .tools
                .iter()
                .map(|tool| {
                    json!({
                        "type": "function", "function": tool,
                    })
                })
                .collect(),
            options: self.options,
            tool_choice,
            response_format,
            stream,
            stream_options: (stream && self.options.stream_usage)
                .then(|| json!({"include_usage": true})),
        })
        .map_err(|_| Error::Request("invalid OpenAI request"))
    }

    fn anthropic(
        &self,
        stream: bool,
        tool_choice: Option<Value>,
        response_format: Option<Value>,
    ) -> Result<Vec<u8>, Error> {
        if self.options.seed.is_some() || self.options.user.is_some() {
            return Err(Error::Request("Anthropic seed and user options"));
        }
        if self.messages.iter().any(|message| message.name.is_some()) {
            return Err(Error::Request("Anthropic text message metadata"));
        }
        let first_turn = self
            .messages
            .iter()
            .position(|message| !matches!(message.role, Role::System | Role::Developer))
            .ok_or(Error::Request("Anthropic conversation requires a turn"))?;
        let (instructions, turns) = self.messages.split_at(first_turn);
        if turns
            .iter()
            .any(|message| !matches!(message.role, Role::User | Role::Assistant | Role::Tool))
        {
            return Err(Error::Request("Anthropic text message role or order"));
        }
        let system: Vec<_> = instructions
            .iter()
            .map(|message| json!({"type": "text", "text": message.content}))
            .collect();
        let mut payload = json!({
            "model": self.model,
            "messages": anthropic_turns(turns),
            "stream": stream,
            "max_tokens": self.options.max_tokens.unwrap_or(1024),
        });
        for (key, value) in [
            ("system", (!system.is_empty()).then(|| json!(system))),
            ("tool_choice", tool_choice),
            ("output_config", response_format.map(|format| json!({"format": format}))),
            ("tools", (!self.options.tools.is_empty()).then(|| json!(
                self.options.tools.iter().map(|tool| json!({
                    "name": tool.name, "description": tool.description, "input_schema": tool.parameters,
                })).collect::<Vec<_>>()
            ))),
            (
                "temperature",
                self.options.temperature.map(|value| json!(value)),
            ),
            ("top_p", self.options.top_p.map(|value| json!(value))),
            (
                "stop_sequences",
                self.options.stop.as_ref().map(|value| json!(value)),
            ),
        ] {
            if let Some(value) = value {
                payload[key] = value;
            }
        }
        serde_json::to_vec(&payload).map_err(|_| Error::Request("invalid Anthropic request"))
    }
}

#[derive(Serialize)]
struct OpenAiMessage<'a> {
    role: Role,
    content: OpenAiContent<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tool_call_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    tool_calls: Vec<Value>,
}

#[derive(Serialize)]
#[serde(untagged)]
enum OpenAiContent<'a> {
    Text(&'a str),
    Blocks(Vec<Value>),
}

impl<'a> From<&'a Message> for OpenAiMessage<'a> {
    fn from(message: &'a Message) -> Self {
        Self {
            role: message.role,
            content: if message.images.is_empty() {
                OpenAiContent::Text(&message.content)
            } else {
                OpenAiContent::Blocks(content_blocks(
                    &message.content,
                    &message.images,
                    Protocol::OpenAi,
                ))
            },
            name: message.name.as_deref(),
            tool_call_id: message.tool_call_id.as_deref(),
            tool_calls: message
                .tool_calls
                .iter()
                .map(|call| {
                    json!({
                        "id": call.id, "type": "function",
                        "function": {"name": call.name, "arguments": call.arguments.to_string()},
                    })
                })
                .collect(),
        }
    }
}

fn anthropic_turns(turns: &[Message]) -> Vec<Value> {
    let mut encoded = Vec::with_capacity(turns.len());
    let mut results = Vec::new();
    for message in turns {
        if message.role == Role::Tool {
            results.push(json!({
                "type": "tool_result", "tool_use_id": message.tool_call_id, "content": message.content,
            }));
            continue;
        }
        if !results.is_empty() {
            encoded.push(json!({"role": "user", "content": std::mem::take(&mut results)}));
        }
        if !message.images.is_empty() {
            let content = content_blocks(&message.content, &message.images, Protocol::Anthropic);
            encoded.push(json!({"role": message.role, "content": content}));
            continue;
        }
        if message.tool_calls.is_empty() {
            encoded.push(json!({"role": message.role, "content": message.content}));
            continue;
        }
        let mut blocks = Vec::with_capacity(message.tool_calls.len() + 1);
        if !message.content.is_empty() {
            blocks.push(json!({"type": "text", "text": message.content}));
        }
        blocks.extend(message.tool_calls.iter().map(|call| {
            json!({
                "type": "tool_use", "id": call.id, "name": call.name, "input": call.arguments,
            })
        }));
        encoded.push(json!({"role": "assistant", "content": blocks}));
    }
    if !results.is_empty() {
        encoded.push(json!({"role": "user", "content": results}));
    }
    encoded
}

/// Provider-reported token usage.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct Usage {
    /// Input tokens.
    #[serde(alias = "prompt_tokens")]
    pub input_tokens: u64,
    /// Output tokens.
    #[serde(alias = "completion_tokens")]
    pub output_tokens: u64,
}

/// One completed assistant turn.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct CompletionChoice {
    /// Choice index.
    pub index: u32,
    /// Assistant message.
    #[serde(deserialize_with = "openai_message")]
    pub message: Message,
    /// Provider's original finish reason.
    pub finish_reason: Option<String>,
}

fn openai_message<'de, D: serde::Deserializer<'de>>(value: D) -> Result<Message, D::Error> {
    #[derive(Deserialize)]
    struct WireMessage {
        role: Role,
        content: Option<String>,
        name: Option<String>,
        tool_calls: Option<Vec<WireCall>>,
        function_call: Option<serde::de::IgnoredAny>,
        refusal: Option<String>,
    }

    #[derive(Deserialize)]
    struct WireCall {
        id: String,
        #[serde(rename = "type")]
        kind: String,
        function: WireFunction,
    }

    #[derive(Deserialize)]
    struct WireFunction {
        name: String,
        arguments: String,
    }

    use serde::de::Error as _;
    let wire = WireMessage::deserialize(value)?;
    if wire.refusal.is_some_and(|text| !text.is_empty()) {
        return Err(D::Error::custom("provider refused the requested output"));
    }
    if wire.function_call.is_some() {
        return Err(D::Error::custom("unsupported legacy function call"));
    }
    let mut tool_calls = Vec::new();
    for call in wire.tool_calls.unwrap_or_default() {
        if call.kind != "function" {
            return Err(D::Error::custom("unsupported tool call type"));
        }
        tool_calls.push(ToolCall {
            id: call.id,
            name: call.function.name,
            arguments: serde_json::from_str(&call.function.arguments).map_err(D::Error::custom)?,
        });
    }
    if wire.content.is_none() && tool_calls.is_empty() {
        return Err(D::Error::custom("missing assistant content"));
    }
    Ok(Message {
        role: wire.role,
        content: wire.content.unwrap_or_default(),
        images: Vec::new(),
        name: wire.name,
        tool_call_id: None,
        tool_calls,
        responses_output: None,
    })
}

fn completed_choice(choice: &CompletionChoice) -> bool {
    let calls = &choice.message.tool_calls;
    let expects_tools = matches!(
        choice.finish_reason.as_deref(),
        Some("tool_calls" | "tool_use")
    );
    let mut ids = HashSet::new();
    choice.message.role == Role::Assistant
        && expects_tools != calls.is_empty()
        && calls.iter().all(|call| {
            !call.id.is_empty()
                && !call.name.is_empty()
                && call.arguments.is_object()
                && ids.insert(&call.id)
        })
}

/// Completed provider response.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct Completion {
    /// Provider response identity.
    pub id: String,
    /// Provider-reported model.
    pub model: String,
    /// Completion choices.
    pub choices: Vec<CompletionChoice>,
    /// Token accounting when present.
    pub usage: Option<Usage>,
}

impl Completion {
    pub(crate) fn decode(protocol: Protocol, bytes: &[u8]) -> Result<Self, Error> {
        let completion = match protocol {
            Protocol::OpenAi => {
                serde_json::from_slice(bytes).map_err(|_| openai_completion_error(bytes))?
            }
            Protocol::Anthropic => Self::anthropic(bytes)?,
            Protocol::OpenAiResponses => crate::responses::complete(bytes)?,
        };
        if completion.choices.iter().any(|choice| {
            choice
                .finish_reason
                .as_deref()
                .is_some_and(crate::error::refusal_reason)
        }) {
            return Err(Error::Refused);
        }
        if completion.id.is_empty()
            || completion.model.is_empty()
            || completion.choices.is_empty()
            || completion
                .choices
                .iter()
                .any(|choice| !completed_choice(choice))
        {
            return Err(Error::Response);
        }
        Ok(completion)
    }

    fn anthropic(bytes: &[u8]) -> Result<Self, Error> {
        #[derive(Deserialize)]
        struct Response {
            id: String,
            model: String,
            role: Role,
            content: Vec<Value>,
            stop_reason: Option<String>,
            usage: Option<Usage>,
        }
        let response: Response = serde_json::from_slice(bytes).map_err(|_| Error::Response)?;
        if response
            .stop_reason
            .as_deref()
            .is_some_and(crate::error::refusal_reason)
        {
            return Err(Error::Refused);
        }
        let mut content = String::new();
        let mut tool_calls = Vec::new();
        for block in response.content {
            match block["type"].as_str() {
                Some("text") => content.push_str(block["text"].as_str().ok_or(Error::Response)?),
                Some("tool_use") => tool_calls.push(ToolCall {
                    id: block["id"].as_str().ok_or(Error::Response)?.into(),
                    name: block["name"].as_str().ok_or(Error::Response)?.into(),
                    arguments: block["input"].clone(),
                }),
                _ => return Err(Error::Response),
            }
        }
        Ok(Self {
            id: response.id,
            model: response.model,
            choices: vec![CompletionChoice {
                index: 0,
                message: Message {
                    role: response.role,
                    content,
                    images: Vec::new(),
                    name: None,
                    tool_call_id: None,
                    tool_calls,
                    responses_output: None,
                },
                finish_reason: response.stop_reason,
            }],
            usage: response.usage,
        })
    }
}

fn openai_completion_error(bytes: &[u8]) -> Error {
    let Ok(payload) = serde_json::from_slice::<Value>(bytes) else {
        return Error::Response;
    };
    if payload["choices"].as_array().is_some_and(|choices| {
        choices.iter().any(|choice| {
            choice["message"]["refusal"]
                .as_str()
                .is_some_and(|text| !text.is_empty())
                || choice["finish_reason"]
                    .as_str()
                    .is_some_and(crate::error::refusal_reason)
        })
    }) {
        Error::Refused
    } else {
        Error::Response
    }
}
