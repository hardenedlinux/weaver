// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Incremental SSE framing and provider turn decoding.

use bytes::{Bytes, BytesMut};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use tokio_sse_codec::{Frame, SseDecodeError, SseDecoder};
use tokio_util::codec::Decoder as _;

use crate::{Error, EventStream, Protocol, ToolCall, Usage};

/// A provider-returned thinking fragment. Debug formatting hides its content.
#[derive(Eq, PartialEq)]
pub struct ThinkingDelta(String);

impl ThinkingDelta {
    /// Returns the provider-returned fragment for explicit presentation.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Debug for ThinkingDelta {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ThinkingDelta")
            .field("bytes", &self.0.len())
            .finish()
    }
}

/// A provider-neutral event for a single assistant turn.
#[derive(Debug, Eq, PartialEq)]
pub enum TurnEvent {
    /// Text that can be displayed as it arrives.
    Text(String),
    /// Provider-returned thinking, distinct from final-answer text.
    Thinking(ThinkingDelta),
    /// Successful terminal event. The Harness can now execute these calls.
    Finished {
        /// Provider finish reason.
        reason: String,
        /// Response identity reported by the provider.
        identity: Option<TurnIdentity>,
        /// Provider usage, when available.
        usage: Option<Usage>,
        /// Complete calls ordered by the provider's index.
        tool_calls: Vec<ToolCall>,
        /// Opaque output for stateless Responses continuation.
        responses_output: Option<crate::ResponsesOutput>,
        /// Ordered Anthropic content blocks for continuation, including thinking.
        anthropic_output: Option<crate::AnthropicOutput>,
    },
}

/// Provider-reported identity of an assistant turn.
#[derive(Debug, Eq, PartialEq)]
pub struct TurnIdentity {
    /// Provider response identifier.
    pub id: String,
    /// Provider model identifier.
    pub model: String,
}

/// Pull-based SSE exchange on the caller's Tokio runtime.
pub struct TurnStream {
    body: Option<EventStream>,
    framing: SseFraming,
    decoder: Decoder,
}

impl TurnStream {
    pub(crate) fn new(body: EventStream, protocol: Protocol, response_limit: usize) -> Self {
        Self {
            body: Some(body),
            framing: SseFraming::new(response_limit),
            decoder: Decoder {
                protocol,
                tools: BTreeMap::new(),
                finish: None,
                identity: None,
                usage: None,
                anthropic_started: false,
                anthropic_block: None,
                anthropic_output: BTreeMap::new(),
                responses_text: Sha256::new(),
            },
        }
    }

    /// Convert this turn to a pull stream for Tokio consumers.
    ///
    /// Polling drives the same response body directly. Dropping the stream
    /// cancels the exchange without a background task or queue.
    pub fn into_stream(self) -> impl tokio_stream::Stream<Item = Result<TurnEvent, Error>> + Send {
        async_stream::try_stream! {
            let mut turn = self;
            while let Some(event) = turn.next_event().await? {
                yield event;
            }
        }
    }

    /// Read one model event. Dropping the stream cancels the exchange.
    ///
    /// # Errors
    /// Returns transport, limit, or protocol errors. EOF before the provider's
    /// terminal event is a protocol error. After an error the stream is closed.
    pub async fn next_event(&mut self) -> Result<Option<TurnEvent>, Error> {
        let result = self.read_event().await;
        if result.is_err() || matches!(result, Ok(Some(TurnEvent::Finished { .. }))) {
            self.body = None;
            self.framing = SseFraming::new(8);
            self.decoder.tools.clear();
        }
        result
    }

    async fn read_event(&mut self) -> Result<Option<TurnEvent>, Error> {
        let Some(body) = &mut self.body else {
            return Ok(None);
        };
        loop {
            // Buffered control frames can be ready without polling Tokio I/O.
            tokio::task::consume_budget().await;
            match self.framing.next()? {
                Some(Frame::Event(event)) => {
                    if let Some(event) = self.decoder.accept(&event.data)? {
                        return Ok(Some(event));
                    }
                }
                Some(Frame::Comment(_) | Frame::Retry(_)) => {}
                None => {
                    let chunk = body.next_chunk().await?.ok_or(Error::Response)?;
                    self.framing.push(&chunk);
                }
            }
        }
    }
}

struct SseFraming {
    pending: BytesMut,
    codec: SseDecoder<Bytes>,
    after_cr: bool,
}

impl SseFraming {
    fn new(response_limit: usize) -> Self {
        Self {
            pending: BytesMut::new(),
            // EventStream enforces the exact response budget.
            codec: SseDecoder::with_max_size(response_limit.max(8)),
            after_cr: false,
        }
    }

    fn push(&mut self, bytes: &[u8]) {
        // The codec needs LF to dispatch a frame. Normalize CR, including
        // CRLF split between HTTP chunks, before passing bytes to the codec.
        let mut remaining = bytes;
        while !remaining.is_empty() {
            if std::mem::take(&mut self.after_cr) && remaining[0] == b'\n' {
                remaining = &remaining[1..];
            }
            let Some(cr) = remaining.iter().position(|byte| *byte == b'\r') else {
                self.pending.extend_from_slice(remaining);
                break;
            };
            self.pending.extend_from_slice(&remaining[..cr]);
            self.pending.extend_from_slice(b"\n");
            remaining = &remaining[cr + 1..];
            self.after_cr = true;
        }
    }

    fn next(&mut self) -> Result<Option<Frame<Bytes>>, Error> {
        self.codec
            .decode(&mut self.pending)
            .map_err(|error| match error {
                SseDecodeError::ExceededSizeLimit(_) => Error::Limit,
                _ => Error::Response,
            })
    }
}

struct PartialCall {
    id: String,
    name: String,
    arguments: String,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum Block {
    Text,
    Tool,
    Thinking,
    RedactedThinking,
}

struct Decoder {
    protocol: Protocol,
    tools: BTreeMap<u64, PartialCall>,
    finish: Option<String>,
    identity: Option<TurnIdentity>,
    usage: Option<Usage>,
    anthropic_started: bool,
    anthropic_block: Option<(u64, Block)>,
    anthropic_output: BTreeMap<u64, Value>,
    responses_text: Sha256,
}

impl Decoder {
    fn accept(&mut self, data: &[u8]) -> Result<Option<TurnEvent>, Error> {
        if self.protocol == Protocol::OpenAi && data == b"[DONE]" {
            return self.terminal().map(Some);
        }
        let event: Value = serde_json::from_slice(data).map_err(|_| Error::Response)?;
        if let Some(error) = event.get("error").filter(|value| !value.is_null()) {
            return Err(Error::provider_event(error).unwrap_or(Error::Response));
        }
        match self.protocol {
            Protocol::OpenAi => self.openai(&event),
            Protocol::Anthropic => self.anthropic(&event),
            Protocol::OpenAiResponses => {
                let decoded = crate::responses::event(event)?;
                match &decoded {
                    Some(TurnEvent::Text(text)) => self.responses_text.update(text.as_bytes()),
                    Some(TurnEvent::Finished {
                        responses_output: Some(output),
                        ..
                    }) => {
                        let expected = self.responses_text.clone().finalize();
                        if !output.matches_streamed_text(&expected)? {
                            return Err(Error::Response);
                        }
                    }
                    _ => {}
                }
                Ok(decoded)
            }
        }
    }

    fn terminal(&mut self) -> Result<TurnEvent, Error> {
        let reason = self.finish.take().ok_or(Error::Response)?;
        if crate::error::refusal_reason(&reason) {
            return Err(Error::Refused);
        }
        let expects_tools = matches!(reason.as_str(), "tool_calls" | "tool_use");
        // A length or refusal stop can carry a partial call. It is never executable.
        if !self.tools.is_empty()
            && matches!(reason.as_str(), "stop" | "end_turn" | "stop_sequence")
        {
            return Err(Error::Response);
        }
        if !expects_tools {
            self.tools.clear();
        } else if self.tools.is_empty() {
            return Err(Error::Response);
        }
        let mut ids = HashSet::new();
        let mut calls = Vec::with_capacity(self.tools.len());
        for (_, call) in std::mem::take(&mut self.tools) {
            let arguments = if self.protocol == Protocol::Anthropic && call.arguments.is_empty() {
                "{}"
            } else {
                &call.arguments
            };
            let arguments = serde_json::from_str::<Value>(arguments)
                .ok()
                .filter(Value::is_object)
                .ok_or(Error::Response)?;
            if !ids.insert(call.id.clone()) {
                return Err(Error::Response);
            }
            calls.push(ToolCall {
                id: call.id,
                name: call.name,
                arguments,
            });
        }
        let anthropic_output = if self.protocol == Protocol::Anthropic {
            let blocks = std::mem::take(&mut self.anthropic_output)
                .into_values()
                .collect();
            let (output, _, observed_calls) = crate::AnthropicOutput::parse(blocks)?;
            if observed_calls != calls {
                return Err(Error::Response);
            }
            Some(output)
        } else {
            None
        };
        Ok(TurnEvent::Finished {
            reason,
            identity: self.identity.take(),
            usage: self.usage.take(),
            tool_calls: calls,
            responses_output: None,
            anthropic_output,
        })
    }

    fn openai(&mut self, event: &Value) -> Result<Option<TurnEvent>, Error> {
        if self.identity.is_none() {
            self.identity = identity(event);
        }
        if let Some(usage) = event.get("usage").filter(|value| !value.is_null()) {
            self.usage = Some(serde_json::from_value(usage.clone()).map_err(|_| Error::Response)?);
        }
        let choices = event["choices"].as_array().ok_or(Error::Response)?;
        let choice = match choices.as_slice() {
            [] => return Ok(None),
            [choice] if choice["index"].as_u64() == Some(0) && self.finish.is_none() => choice,
            _ => return Err(Error::Response),
        };
        let delta = &choice["delta"];
        if delta["refusal"]
            .as_str()
            .is_some_and(|text| !text.is_empty())
        {
            return Err(Error::Refused);
        }
        if let Some(calls) = delta.get("tool_calls") {
            for call in calls.as_array().ok_or(Error::Response)? {
                self.openai_tool(call)?;
            }
        }
        if let Some(reason) = choice["finish_reason"].as_str() {
            self.finish = Some(reason.to_owned());
        }
        Ok(delta["content"]
            .as_str()
            .filter(|text| !text.is_empty())
            .map(text_event))
    }

    fn openai_tool(&mut self, call: &Value) -> Result<(), Error> {
        let index = index(call)?;
        let function = &call["function"];
        if let Some(id) = call["id"].as_str() {
            if call["type"].as_str() != Some("function") {
                return Err(Error::Response);
            }
            let name = required_string(&function["name"])?;
            self.start_tool(index, id, name)?;
        }
        let partial = self.tools.get_mut(&index).ok_or(Error::Response)?;
        if let Some(arguments) = function.get("arguments").filter(|value| !value.is_null()) {
            partial
                .arguments
                .push_str(arguments.as_str().ok_or(Error::Response)?);
        }
        Ok(())
    }

    fn anthropic(&mut self, event: &Value) -> Result<Option<TurnEvent>, Error> {
        let kind = required_string(&event["type"])?;
        match kind {
            "ping" => return Ok(None),
            "message_start" if !self.anthropic_started => {
                self.anthropic_started = true;
                self.identity = identity(&event["message"]);
                let usage = &event["message"]["usage"];
                self.usage = Some(Usage {
                    input_tokens: usage["input_tokens"].as_u64().ok_or(Error::Response)?,
                    output_tokens: usage["output_tokens"].as_u64().ok_or(Error::Response)?,
                });
                return Ok(None);
            }
            _ if !self.anthropic_started => return Err(Error::Response),
            "message_stop" if self.anthropic_block.is_none() => return self.terminal().map(Some),
            _ if self.finish.is_some() => return Err(Error::Response),
            _ => {}
        }

        match kind {
            "content_block_start" if self.anthropic_block.is_none() => self.anthropic_start(event),
            "content_block_delta" => self.anthropic_delta(event),
            "content_block_stop"
                if self
                    .anthropic_block
                    .is_some_and(|(active, _)| event["index"].as_u64() == Some(active)) =>
            {
                self.anthropic_stop()?;
                Ok(None)
            }
            "message_delta" if self.anthropic_block.is_none() => {
                if let Some(reason) = event["delta"]["stop_reason"].as_str() {
                    self.finish = Some(reason.to_owned());
                }
                if let Some(tokens) = event["usage"]["output_tokens"].as_u64() {
                    self.usage.as_mut().ok_or(Error::Response)?.output_tokens = tokens;
                }
                Ok(None)
            }
            _ => Err(Error::Response),
        }
    }

    fn anthropic_start(&mut self, event: &Value) -> Result<Option<TurnEvent>, Error> {
        let index = index(event)?;
        let block = &event["content_block"];
        let (kind, text) = match required_string(&block["type"])? {
            "tool_use" => {
                self.start_tool(
                    index,
                    required_string(&block["id"])?,
                    required_string(&block["name"])?,
                )?;
                let input = block["input"].as_object().ok_or(Error::Response)?;
                // Anthropic starts streamed tool input with an empty object.
                if !input.is_empty() {
                    return Err(Error::Response);
                }
                (Block::Tool, None)
            }
            "text" => (
                Block::Text,
                Some(block["text"].as_str().ok_or(Error::Response)?)
                    .filter(|text| !text.is_empty())
                    .map(text_event),
            ),
            "thinking" if block["thinking"].is_string() => (
                Block::Thinking,
                block["thinking"]
                    .as_str()
                    .filter(|text| !text.is_empty())
                    .map(|text| TurnEvent::Thinking(ThinkingDelta(text.to_owned()))),
            ),
            "redacted_thinking" if block["data"].is_string() => (Block::RedactedThinking, None),
            _ => return Err(Error::Response),
        };
        if self.anthropic_output.insert(index, block.clone()).is_some() {
            return Err(Error::Response);
        }
        self.anthropic_block = Some((index, kind));
        Ok(text)
    }

    fn anthropic_delta(&mut self, event: &Value) -> Result<Option<TurnEvent>, Error> {
        let index = index(event)?;
        let (active, block) = self.anthropic_block.ok_or(Error::Response)?;
        if active != index {
            return Err(Error::Response);
        }
        let delta = &event["delta"];
        match (block, required_string(&delta["type"])?) {
            (Block::Text, "text_delta") => {
                let text = delta["text"].as_str().ok_or(Error::Response)?;
                self.append_anthropic_field(index, "text", text)?;
                Ok(Some(text_event(text)))
            }
            (Block::Tool, "input_json_delta") => {
                let partial = self.tools.get_mut(&index).ok_or(Error::Response)?;
                partial
                    .arguments
                    .push_str(delta["partial_json"].as_str().ok_or(Error::Response)?);
                Ok(None)
            }
            (Block::Thinking, "thinking_delta" | "signature_delta") => {
                let field = if delta["type"] == "thinking_delta" {
                    "thinking"
                } else {
                    "signature"
                };
                let part = delta[field].as_str().ok_or(Error::Response)?;
                self.append_anthropic_field(index, field, part)?;
                if field == "thinking" && !part.is_empty() {
                    Ok(Some(TurnEvent::Thinking(ThinkingDelta(part.to_owned()))))
                } else {
                    Ok(None)
                }
            }
            _ => Err(Error::Response),
        }
    }

    fn append_anthropic_field(
        &mut self,
        index: u64,
        field: &str,
        value: &str,
    ) -> Result<(), Error> {
        let block = self
            .anthropic_output
            .get_mut(&index)
            .and_then(Value::as_object_mut)
            .ok_or(Error::Response)?;
        let entry = block
            .entry(field)
            .or_insert_with(|| Value::String(String::new()));
        let Value::String(text) = entry else {
            return Err(Error::Response);
        };
        text.push_str(value);
        Ok(())
    }

    fn anthropic_stop(&mut self) -> Result<(), Error> {
        let (index, kind) = self.anthropic_block.take().ok_or(Error::Response)?;
        if kind == Block::Tool {
            let call = self.tools.get(&index).ok_or(Error::Response)?;
            let input: Value = if call.arguments.is_empty() {
                serde_json::json!({})
            } else {
                serde_json::from_str(&call.arguments).map_err(|_| Error::Response)?
            };
            if !input.is_object() {
                return Err(Error::Response);
            }
            self.anthropic_output
                .get_mut(&index)
                .and_then(Value::as_object_mut)
                .ok_or(Error::Response)?
                .insert("input".into(), input);
        }
        Ok(())
    }

    fn start_tool(&mut self, index: u64, id: &str, name: &str) -> Result<(), Error> {
        use std::collections::btree_map::Entry;
        let Entry::Vacant(entry) = self.tools.entry(index) else {
            return Err(Error::Response);
        };
        if id.is_empty() || name.is_empty() {
            return Err(Error::Response);
        }
        entry.insert(PartialCall {
            id: id.into(),
            name: name.into(),
            arguments: String::new(),
        });
        Ok(())
    }
}

fn index(value: &Value) -> Result<u64, Error> {
    value["index"].as_u64().ok_or(Error::Response)
}

fn required_string(value: &Value) -> Result<&str, Error> {
    value
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or(Error::Response)
}

fn text_event(text: &str) -> TurnEvent {
    TurnEvent::Text(text.to_owned())
}

#[cfg(test)]
#[path = "../tests/unit/stream.rs"]
mod tests;

fn identity(value: &Value) -> Option<TurnIdentity> {
    Some(TurnIdentity {
        id: required_string(&value["id"]).ok()?.to_owned(),
        model: required_string(&value["model"]).ok()?.to_owned(),
    })
}
