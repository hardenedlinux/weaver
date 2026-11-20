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

/// Rehydrate a caller-held fragment at an inert transport boundary. This does
/// not authenticate its origin or grant permission to display or publish it.
impl From<String> for ThinkingDelta {
    fn from(text: String) -> Self {
        Self(text)
    }
}

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
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct TurnIdentity {
    /// Provider response identifier.
    pub id: String,
    /// Provider model identifier.
    pub model: String,
}

/// Pull-based SSE exchange on the caller's Tokio runtime.
pub struct TurnStream {
    body: Option<EventStream>,
    codec: TurnDecoder,
}

/// Bounded, transport-independent SSE decoder for one provider turn.
///
/// Feed bytes from an already-authorized transport, then drain `next_event`.
/// This type neither sends requests nor grants permission to execute tools.
pub struct TurnDecoder {
    framing: SseFraming,
    decoder: Option<Decoder>,
    remaining: usize,
    completed: bool,
    terminal_usage: Option<crate::TokenCategories>,
    coordinates: bool,
    observation_state: crate::stream_observation::ObservationState,
}

impl TurnDecoder {
    /// Creates a decoder with a total wire-byte budget, including control frames.
    pub fn new(protocol: Protocol, response_limit: usize) -> Self {
        Self {
            framing: SseFraming::new(response_limit),
            decoder: Some(Decoder {
                protocol,
                tools: BTreeMap::new(),
                finish: None,
                identity: None,
                usage: None,
                anthropic_started: false,
                anthropic_block: None,
                anthropic_output: BTreeMap::new(),
                responses_text: Sha256::new(),
                expected_model: None,
                categories: None,
            }),
            remaining: response_limit,
            completed: false,
            terminal_usage: None,
            coordinates: false,
            observation_state: Default::default(),
        }
    }

    /// Returns disjoint token categories only after a complete, validated turn.
    /// Missing provider usage stays unknown; counts grant no settlement authority.
    pub fn terminal_usage(&self) -> Option<crate::TokenCategories> {
        self.terminal_usage
    }

    /// Requires any reported model identity to match the source-selected model.
    /// The guarded caller also requires a terminal identity before releasing tools.
    pub fn with_expected_model(mut self, model: String) -> Self {
        if let Some(decoder) = &mut self.decoder {
            decoder.expected_model = Some(model);
        }
        self
    }

    /// Supplies wire bytes. Errors close the decoder and discard partial tools.
    ///
    /// # Errors
    /// Returns `Limit` on budget exhaustion or `Response` after closure.
    pub fn push_bytes(&mut self, bytes: &[u8]) -> Result<(), Error> {
        if self.decoder.is_none() {
            return Err(Error::Response);
        }
        if bytes.len() > self.remaining {
            self.close();
            return Err(Error::Limit);
        }
        self.remaining -= bytes.len();
        self.framing.push(bytes);
        Ok(())
    }

    /// Decodes one available event without polling or owning a transport.
    ///
    /// `None` means more bytes are needed, or the turn has closed. Tools appear
    /// only in a validated `Finished` event; that event closes the decoder.
    ///
    /// # Errors
    /// Returns a provider, framing or protocol error and discards partial state.
    pub fn next_event(&mut self) -> Result<Option<TurnEvent>, Error> {
        loop {
            match self.next_frame()? {
                Some(crate::TurnObservation {
                    event: Some(event), ..
                }) => return Ok(Some(event)),
                Some(_) => {}
                None => return Ok(None),
            }
        }
    }

    /// Drain one validated observation, including standard protocol coordinates.
    /// Tool fragments remain internal; coordinates convey no execution authority.
    /// Select this mode before decoding the first frame and use it for the turn.
    ///
    /// # Errors
    /// Rejects malformed coordinates and the same framing/protocol errors as next_event.
    pub fn next_observation(&mut self) -> Result<Option<crate::TurnObservation>, Error> {
        self.coordinates = true;
        loop {
            match self.next_frame()? {
                Some(observation)
                    if observation.event.is_some() || observation.metadata.is_some() =>
                {
                    return Ok(Some(observation));
                }
                Some(_) => {}
                None => return Ok(None),
            }
        }
    }

    fn next_frame(&mut self) -> Result<Option<crate::TurnObservation>, Error> {
        let result = self.decode_frame();
        if matches!(
            result,
            Ok(Some(crate::TurnObservation {
                event: Some(TurnEvent::Finished { .. }),
                ..
            }))
        ) {
            self.terminal_usage = self.decoder.as_ref().and_then(|decoder| decoder.categories);
            self.completed = true;
            self.close();
        } else if result.is_err() {
            self.terminal_usage = None;
            self.close();
        }
        result
    }

    fn decode_frame(&mut self) -> Result<Option<crate::TurnObservation>, Error> {
        let Some(decoder) = &mut self.decoder else {
            return Ok(None);
        };
        match self.framing.next()? {
            Some(Frame::Event(event)) => {
                let observation = decoder.accept(&event.data, self.coordinates)?;
                if self.coordinates {
                    self.observation_state
                        .observe(decoder.protocol, &observation)?;
                }
                Ok(Some(observation))
            }
            Some(Frame::Comment(_) | Frame::Retry(_)) => Ok(Some(crate::TurnObservation {
                event: None,
                metadata: None,
            })),
            None => Ok(None),
        }
    }

    /// Checks EOF after all supplied bytes have been drained.
    ///
    /// # Errors
    /// Incomplete or failed turns return `Response` and discard partial state.
    pub fn finish(&mut self) -> Result<(), Error> {
        if self.completed {
            Ok(())
        } else {
            self.close();
            Err(Error::Response)
        }
    }

    fn close(&mut self) {
        self.decoder = None;
        self.observation_state = Default::default();
        self.framing = SseFraming::new(8);
        self.remaining = 0;
    }
}

impl TurnStream {
    /// Returns normalized provider usage after a validated terminal event.
    /// These reported counts do not authenticate pricing or settlement.
    pub fn terminal_usage(&self) -> Option<crate::TokenCategories> {
        self.codec.terminal_usage()
    }

    pub(crate) fn new(body: EventStream, protocol: Protocol, response_limit: usize) -> Self {
        Self {
            body: Some(body),
            codec: TurnDecoder::new(protocol, response_limit),
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
            self.codec.close();
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
            match self.codec.next_frame()? {
                Some(crate::TurnObservation {
                    event: Some(event), ..
                }) => return Ok(Some(event)),
                Some(_) => continue,
                None => {}
            }
            let chunk = body.next_chunk().await?.ok_or(Error::Response)?;
            self.codec.push_bytes(&chunk)?;
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
            // TurnDecoder and EventStream enforce total wire-byte budgets.
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
    expected_model: Option<String>,
    categories: Option<crate::TokenCategories>,
}

impl Decoder {
    fn accept(&mut self, data: &[u8], coordinates: bool) -> Result<crate::TurnObservation, Error> {
        if self.protocol == Protocol::OpenAi && data == b"[DONE]" {
            return Ok(crate::TurnObservation {
                event: Some(self.terminal()?),
                metadata: None,
            });
        }
        let event: Value = serde_json::from_slice(data).map_err(|_| Error::Response)?;
        let mut metadata = if coordinates {
            crate::stream_observation::project(self.protocol, &event)?
        } else {
            None
        };
        let had_identity = self.identity.is_some();
        let stopped = (coordinates
            && self.protocol == Protocol::Anthropic
            && event["type"] == "content_block_stop")
            .then(|| event["index"].as_u64())
            .flatten();
        if self.protocol == Protocol::OpenAiResponses {
            let response = &event["response"];
            if response["id"].is_string() && response["model"].is_string() {
                let observed = TurnIdentity {
                    id: crate::stream_observation::text(&response["id"])?,
                    model: crate::stream_observation::text(&response["model"])?,
                };
                if self.identity.as_ref().is_some_and(|old| *old != observed) {
                    return Err(Error::Response);
                }
                self.identity = Some(observed);
            }
        }
        let decoded = self.accept_value(event)?;
        if coordinates
            && self.protocol == Protocol::OpenAi
            && !had_identity
            && self.identity.is_some()
        {
            metadata
                .get_or_insert(crate::TurnMetadata {
                    identity: None,
                    usage: None,
                    position: None,
                    control: None,
                })
                .control = Some(crate::TurnControl::Started);
        }
        if let Some(index) = stopped {
            let block = self.anthropic_output.get(&index).ok_or(Error::Response)?;
            let kind = crate::stream_observation::block_kind(&block["type"])?;
            let signature = block
                .get("signature")
                .and_then(Value::as_str)
                .map(str::to_owned);
            metadata.as_mut().ok_or(Error::Response)?.control =
                Some(crate::TurnControl::AnthropicStop {
                    index,
                    kind,
                    signature,
                });
        }
        if let Some(metadata) = &mut metadata {
            metadata.identity = self.identity.clone();
            if matches!(metadata.control, Some(crate::TurnControl::Started)) {
                metadata.usage = self.usage.clone();
            }
        }
        Ok(crate::TurnObservation {
            event: decoded,
            metadata,
        })
    }

    fn accept_value(&mut self, event: Value) -> Result<Option<TurnEvent>, Error> {
        let metadata = match self.protocol {
            Protocol::OpenAi => &event,
            Protocol::Anthropic => &event["message"],
            Protocol::OpenAiResponses => &event["response"],
        };
        if let Some(expected) = &self.expected_model {
            if metadata
                .get("model")
                .is_some_and(|model| model.as_str() != Some(expected))
            {
                return Err(Error::Response);
            }
            if let Some(previous) = &self.identity
                && metadata
                    .get("id")
                    .is_some_and(|id| id.as_str() != Some(&previous.id))
            {
                return Err(Error::Response);
            }
        }
        if let Some(error) = event.get("error").filter(|value| !value.is_null()) {
            return Err(Error::provider_event(error).unwrap_or(Error::Response));
        }
        self.observe_usage(&event)?;
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

    fn observe_usage(&mut self, event: &Value) -> Result<(), Error> {
        use crate::TokenCategories;
        match self.protocol {
            Protocol::OpenAi => {
                if let Some(usage) = event.get("usage").filter(|usage| !usage.is_null()) {
                    self.categories = Some(TokenCategories::openai(usage, true)?);
                }
            }
            Protocol::OpenAiResponses if event["type"] == "response.completed" => {
                if let Some(usage) = event["response"]
                    .get("usage")
                    .filter(|usage| !usage.is_null())
                {
                    self.categories = Some(TokenCategories::openai(usage, false)?);
                }
            }
            Protocol::Anthropic if event["type"] == "message_start" => {
                self.categories = Some(TokenCategories::anthropic_start(
                    &event["message"]["usage"],
                )?);
            }
            Protocol::Anthropic if event["type"] == "message_delta" => {
                if let Some(previous) = self.categories {
                    self.categories = Some(previous.anthropic_delta(&event["usage"])?);
                }
            }
            _ => {}
        }
        Ok(())
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
                if let Some(tokens) = event["usage"]["input_tokens"].as_u64() {
                    self.usage.as_mut().ok_or(Error::Response)?.input_tokens = tokens;
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
        // Content indices are final array positions. Uniqueness alone would
        // allow a later BTreeMap projection to reorder the streamed content.
        if index != self.anthropic_output.len() as u64 {
            return Err(Error::Response);
        }
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
