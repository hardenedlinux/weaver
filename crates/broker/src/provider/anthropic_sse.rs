// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded Anthropic Messages text stream. Only message_stop completes usage.
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, BufReader};
use weaver_contracts::{Error, MAX_CREDITS, ProviderEvent, ProviderEventKind, Result};

pub(super) struct Decoder<R> {
    reader: BufReader<R>,
    line: Vec<u8>,
    data: Vec<u8>,
    model: String,
    bytes: usize,
    frames: usize,
    state: State,
    index: u64,
    tokens: [u64; 4],
}

#[derive(PartialEq, Eq)]
enum State {
    Start,
    BetweenBlocks,
    Text,
    Finished,
    Done,
}

impl<R: AsyncRead + Unpin> Decoder<R> {
    pub(super) fn new(reader: R, model: &str) -> Self {
        Self {
            reader: BufReader::new(reader),
            line: Vec::new(),
            data: Vec::new(),
            model: model.to_owned(),
            bytes: 0,
            frames: 0,
            state: State::Start,
            index: 0,
            tokens: [0; 4],
        }
    }

    pub(super) fn tokens(&self) -> [u64; 4] {
        self.tokens
    }

    pub(super) async fn next(&mut self) -> Result<ProviderEvent> {
        self.next_event(false)
            .await?
            .ok_or(Error::Conflict("Anthropic stream missing terminal event"))
    }

    pub(super) async fn next_buffered(&mut self) -> Result<Option<ProviderEvent>> {
        self.next_event(true).await
    }

    async fn next_event(&mut self, buffered: bool) -> Result<Option<ProviderEvent>> {
        while let Some(frame) = self.frame(buffered).await? {
            if let Some(event) = self.accept(&frame)? {
                return Ok(Some(event));
            }
        }
        Ok(None)
    }

    async fn frame(&mut self, buffered: bool) -> Result<Option<Value>> {
        if buffered && !super::sse_buffer::buffered_sse_record(self.reader.buffer()) {
            return Ok(None);
        }
        self.data.clear();
        let mut kind = None;
        loop {
            self.line.clear();
            let count = (&mut self.reader)
                .take(65537)
                .read_until(b'\n', &mut self.line)
                .await
                .map_err(|_| Error::Conflict("Anthropic stream interrupted"))?;
            if count == 0 || self.line.last() != Some(&b'\n') {
                return Err(Error::Conflict("Anthropic stream missing terminal event"));
            }
            self.bytes += count;
            if count > 65536 || self.bytes > 4 * 1024 * 1024 {
                return Err(Error::Invalid("Anthropic stream byte bound"));
            }
            let line = &self.line[..count - 1];
            let line = line.strip_suffix(b"\r").unwrap_or(line);
            if line.is_empty() {
                if self.data.is_empty() {
                    if kind.is_some() {
                        return Err(Error::Invalid("empty Anthropic event"));
                    }
                    if buffered && !super::sse_buffer::buffered_sse_record(self.reader.buffer()) {
                        return Ok(None);
                    }
                    continue;
                }
                self.frames += 1;
                if self.frames > 4095 {
                    return Err(Error::Invalid("Anthropic frame bound"));
                }
                let frame: Value = weaver_contracts::decode(&self.data)?;
                if frame.get("type").and_then(Value::as_str) != kind {
                    return Err(Error::Invalid("Anthropic event type mismatch"));
                }
                return Ok(Some(frame));
            }
            if let Some(name) = line.strip_prefix(b"event:") {
                let name = name.strip_prefix(b" ").unwrap_or(name);
                if kind.is_some() {
                    return Err(Error::Invalid("duplicate Anthropic event name"));
                }
                kind = Some(match name {
                    b"message_start" => "message_start",
                    b"content_block_start" => "content_block_start",
                    b"content_block_delta" => "content_block_delta",
                    b"content_block_stop" => "content_block_stop",
                    b"message_delta" => "message_delta",
                    b"message_stop" => "message_stop",
                    b"ping" => "ping",
                    _ => return Err(Error::Invalid("unsupported Anthropic event")),
                });
            } else if let Some(data) = line.strip_prefix(b"data:") {
                if !self.data.is_empty() {
                    self.data.push(b'\n');
                }
                self.data
                    .extend_from_slice(data.strip_prefix(b" ").unwrap_or(data));
                if self.data.len() > 65536 {
                    return Err(Error::Invalid("Anthropic event bound"));
                }
            } else if !line.starts_with(b":") {
                return Err(Error::Invalid("unsupported Anthropic SSE field"));
            }
        }
    }

    fn accept(&mut self, frame: &Value) -> Result<Option<ProviderEvent>> {
        let kind = frame.get("type").and_then(Value::as_str);
        let index = frame.get("index").and_then(Value::as_u64);
        let event = match kind {
            Some("ping") => None,
            Some("message_start") if self.state == State::Start => {
                let message = &frame["message"];
                if message["model"].as_str() != Some(&self.model)
                    || message["role"].as_str() != Some("assistant")
                    || !message["content"].as_array().is_some_and(Vec::is_empty)
                    || !message["input_transformations"].is_null()
                    || !message["stop_reason"].is_null()
                {
                    return Err(Error::Denied);
                }
                self.update_usage(&message["usage"], true)?;
                self.state = State::BetweenBlocks;
                None
            }
            Some("content_block_start")
                if self.state == State::BetweenBlocks && index == Some(self.index) =>
            {
                self.state = State::Text;
                Some(text_event(&frame["content_block"], "text")?)
            }
            Some("content_block_delta")
                if self.state == State::Text && index == Some(self.index) =>
            {
                Some(text_event(&frame["delta"], "text_delta")?)
            }
            Some("content_block_stop")
                if self.state == State::Text && index == Some(self.index) =>
            {
                self.index += 1;
                self.state = State::BetweenBlocks;
                None
            }
            Some("message_delta")
                if self.state == State::BetweenBlocks
                    && frame["delta"]["input_transformations"].is_null()
                    && frame["delta"]
                        .get("model")
                        .is_none_or(|model| model.as_str() == Some(&self.model)) =>
            {
                self.update_usage(&frame["usage"], false)?;
                let reason = &frame["delta"]["stop_reason"];
                if reason.is_null() {
                    return Ok(None);
                }
                if !matches!(
                    reason.as_str(),
                    Some("end_turn" | "max_tokens" | "stop_sequence" | "refusal")
                ) {
                    return Err(Error::Invalid("unsupported Anthropic stop reason"));
                }
                self.state = State::Finished;
                Some(ProviderEvent {
                    sequence: 0,
                    kind: ProviderEventKind::Finish,
                    text: String::new(),
                    tokens: 0,
                })
            }
            Some("message_stop") if self.state == State::Finished => {
                self.state = State::Done;
                Some(ProviderEvent {
                    sequence: 0,
                    kind: ProviderEventKind::Done,
                    text: String::new(),
                    tokens: 0,
                })
            }
            _ => return Err(Error::Invalid("Anthropic stream state")),
        };
        Ok(event)
    }

    fn update_usage(&mut self, usage: &Value, initial: bool) -> Result<()> {
        for (i, key) in [
            "input_tokens",
            "cache_read_input_tokens",
            "cache_creation_input_tokens",
            "output_tokens",
        ]
        .iter()
        .enumerate()
        {
            match usage.get(key) {
                None if !initial && i != 3 => {}
                None | Some(Value::Null) if initial && (i == 1 || i == 2) => {}
                Some(value) => {
                    self.tokens[i] = value
                        .as_u64()
                        .filter(|n| *n >= self.tokens[i] && *n <= MAX_CREDITS)
                        .ok_or(Error::Invalid("Anthropic cumulative usage"))?;
                }
                None => return Err(Error::Invalid("Anthropic usage missing")),
            }
        }
        Ok(())
    }
}

fn text_event(data: &Value, kind: &str) -> Result<ProviderEvent> {
    let text = data
        .get("text")
        .and_then(Value::as_str)
        .filter(|_| data["type"].as_str() == Some(kind))
        .ok_or(Error::Invalid("Anthropic text block"))?;
    Ok(ProviderEvent {
        sequence: 0,
        kind: ProviderEventKind::Delta,
        text: text.to_owned(),
        tokens: 0,
    })
}

#[cfg(test)]
#[path = "../../tests/unit/anthropic_sse.rs"]
mod tests;
