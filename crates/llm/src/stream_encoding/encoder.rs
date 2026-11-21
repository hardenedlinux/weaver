// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Pure SSE projection of validated observations; no network or release authority.

use crate::{
    Error, Protocol, TokenCategories, TurnControl, TurnEvent, TurnIdentity, TurnMetadata,
    TurnObservation, Usage,
};
use serde_json::{Value, json};

/// Bounded standard-protocol encoding. Owners must authorize every returned byte.
/// Withheld tool headers pause the tail; the validated terminal output supplies
/// it later without keeping a second copy of text fragments.
pub struct TurnEncoder {
    pub(super) protocol: Protocol,
    pub(super) identity: Option<TurnIdentity>,
    pub(super) started: bool,
    pub(super) closed: bool,
    pub(super) limit: usize,
    pub(super) bytes: usize,
    pub(super) sequence: u64,
    pub(super) created_at: u64,
    pub(super) barrier: Option<u64>,
    pub(super) closed_blocks: usize,
}
impl TurnEncoder {
    /// Select the source protocol, total output-byte budget and gateway response
    /// creation timestamp. This never authenticates observations or authorizes I/O.
    ///
    /// # Errors
    /// Rejects zero or greater than four MiB output budgets.
    pub fn new(protocol: Protocol, limit: usize, created_at: u64) -> Result<Self, Error> {
        if limit == 0 || limit > 4 * 1024 * 1024 {
            return Err(Error::Configuration);
        }
        Ok(Self {
            protocol,
            identity: None,
            started: false,
            closed: false,
            limit,
            bytes: 0,
            sequence: 0,
            created_at,
            barrier: None,
            closed_blocks: 0,
        })
    }

    /// Encode an already validated observation. Terminal categories, when known,
    /// come from the existing usage owner; absence never becomes fabricated zero.
    /// Choose this projection before the first observation and retain its state.
    ///
    /// # Errors
    /// Closes on identity, protocol, lifecycle or byte-budget violations. A closed
    /// encoder cannot replay a terminal or produce more bytes after cancellation.
    pub fn push(
        &mut self,
        observation: &TurnObservation,
        categories: Option<TokenCategories>,
    ) -> Result<Vec<u8>, Error> {
        if self.closed {
            return Err(Error::Response);
        }
        let mut output = Vec::new();
        let result = self.project(observation, categories, &mut output);
        if result.is_err() {
            self.abort();
        }
        result.map(|()| output)
    }

    /// Stop local projection. Previously released bytes are not rolled back.
    pub fn abort(&mut self) {
        self.closed = true;
    }

    fn project(
        &mut self,
        observation: &TurnObservation,
        categories: Option<TokenCategories>,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        if let Some(metadata) = &observation.metadata {
            if let Some(identity) = &metadata.identity {
                self.bind(identity)?;
            }
            if matches!(metadata.control, Some(TurnControl::Started)) && !self.started {
                self.start(metadata, out)?;
                self.started = true;
            }
        }
        if !self.started {
            return Err(Error::Response);
        }
        match self.protocol {
            Protocol::OpenAi => self.chat(observation, categories, out)?,
            Protocol::Anthropic => self.messages(observation, categories, out)?,
            Protocol::OpenAiResponses => self.responses(observation, categories, out)?,
        }
        if matches!(observation.event, Some(TurnEvent::Finished { .. })) {
            self.closed = true;
        }
        Ok(())
    }

    fn bind(&mut self, identity: &TurnIdentity) -> Result<(), Error> {
        if identity.id.is_empty()
            || identity.model.is_empty()
            || identity.id.len() > 1024
            || identity.model.len() > 1024
            || self.identity.as_ref().is_some_and(|old| old != identity)
        {
            return Err(Error::Response);
        }
        if self.identity.is_none() {
            self.identity = Some(identity.clone());
        }
        Ok(())
    }

    fn start(&mut self, metadata: &TurnMetadata, out: &mut Vec<u8>) -> Result<(), Error> {
        let identity = self.identity.as_ref().ok_or(Error::Response)?;
        match self.protocol {
            Protocol::OpenAi => self.chat_delta(
                json!({"role":"assistant","content":""}),
                None,
                None,
                None,
                out,
            ),
            Protocol::Anthropic => {
                let usage = metadata.usage.as_ref().ok_or(Error::Response)?;
                self.emit("message_start",json!({"message":{"id":identity.id,"type":"message","role":"assistant","model":identity.model,"content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":usage.input_tokens,"output_tokens":usage.output_tokens}}}),out)
            }
            Protocol::OpenAiResponses => {
                let response = self.response("in_progress", json!([]), Value::Null)?;
                self.emit("response.created", json!({"response":response}), out)?;
                self.emit("response.in_progress", json!({"response":response}), out)
            }
        }
    }

    pub(super) fn response(
        &self,
        status: &str,
        output: Value,
        usage: Value,
    ) -> Result<Value, Error> {
        let identity = self.identity.as_ref().ok_or(Error::Response)?;
        Ok(
            json!({"id":identity.id,"object":"response","created_at":self.created_at,"model":identity.model,
            "status":status,"output":output,"usage":usage,"error":null,"incomplete_details":null}),
        )
    }

    pub(super) fn terminal_identity(&self, identity: &Option<TurnIdentity>) -> Result<(), Error> {
        if identity.is_none() || identity.as_ref() != self.identity.as_ref() {
            Err(Error::Response)
        } else {
            Ok(())
        }
    }

    pub(super) fn emit(
        &mut self,
        kind: &str,
        mut value: Value,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        if self.protocol != Protocol::OpenAi {
            value["type"] = json!(kind);
        }
        if self.protocol == Protocol::OpenAiResponses {
            value["sequence_number"] = json!(self.sequence);
            self.sequence += 1;
        }
        let data = serde_json::to_vec(&value).map_err(|_| Error::Response)?;
        let mut frame = Vec::new();
        if self.protocol != Protocol::OpenAi {
            frame.extend_from_slice(format!("event: {kind}\n").as_bytes());
        }
        frame.extend_from_slice(b"data: ");
        frame.extend_from_slice(&data);
        frame.extend_from_slice(b"\n\n");
        self.append(&frame, out)
    }

    pub(super) fn append(&mut self, frame: &[u8], out: &mut Vec<u8>) -> Result<(), Error> {
        let bytes = self
            .bytes
            .checked_add(frame.len())
            .filter(|n| *n <= self.limit)
            .ok_or(Error::Limit)?;
        out.extend_from_slice(frame);
        self.bytes = bytes;
        Ok(())
    }
}

pub(super) fn usage(
    usage: &Option<Usage>,
    categories: Option<TokenCategories>,
    protocol: Protocol,
) -> Result<Value, Error> {
    let Some(usage) = usage else {
        return Ok(Value::Null);
    };
    let total = usage
        .input_tokens
        .checked_add(usage.output_tokens)
        .ok_or(Error::Response)?;
    let mut value = if protocol == Protocol::OpenAi {
        json!({"prompt_tokens":usage.input_tokens,"completion_tokens":usage.output_tokens,"total_tokens":total})
    } else {
        json!({"input_tokens":usage.input_tokens,"output_tokens":usage.output_tokens,"total_tokens":total})
    };
    if let Some(c) = categories {
        match protocol {
            Protocol::Anthropic => {
                value["cache_read_input_tokens"] = json!(c.cache_read_input);
                value["cache_creation_input_tokens"] = json!(c.cache_write_input);
            }
            Protocol::OpenAi => {
                value["prompt_tokens_details"] = json!({"cached_tokens":c.cache_read_input,"cache_write_tokens":c.cache_write_input})
            }
            Protocol::OpenAiResponses => {
                value["input_tokens_details"] = json!({"cached_tokens":c.cache_read_input,"cache_write_tokens":c.cache_write_input})
            }
        }
    }
    Ok(value)
}
