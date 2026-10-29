//! Incremental, bounded data-only SSE decoder for single-choice text completions.
use std::io::{BufRead, BufReader, Read};
use weaver_contracts::{Error, ProviderEvent, ProviderEventKind, Result};
pub(super) struct Decoder<R: Read> {
    input: BufReader<R>,
    model: String,
    id: Option<String>,
    bytes: usize,
    events: usize,
    finished: bool,
    usage: bool,
}

#[cfg(test)]
#[path = "../../tests/unit/provider_sse.rs"]
mod tests;
impl<R: Read> Decoder<R> {
    pub(super) fn new(input: R, model: &str) -> Self {
        Self {
            input: BufReader::new(input),
            model: model.into(),
            id: None,
            bytes: 0,
            events: 0,
            finished: false,
            usage: false,
        }
    }
    pub(super) fn next(&mut self) -> Result<ProviderEvent> {
        let mut data = Vec::new();
        loop {
            let line = self.line()?;
            if line.is_empty() {
                if data.is_empty() {
                    continue;
                }
                if data == b"[DONE]" {
                    if !self.finished {
                        return Err(Error::Invalid("SSE done before choice completion"));
                    }
                    return Ok(ProviderEvent {
                        sequence: 0,
                        kind: ProviderEventKind::Done,
                        text: String::new(),
                        tokens: 0,
                    });
                }
                return self.chunk(&data);
            }
            if line.starts_with(b":") {
                continue;
            }
            if let Some(value) = line.strip_prefix(b"data:") {
                let value = value.strip_prefix(b" ").unwrap_or(value);
                if !data.is_empty() {
                    data.push(b'\n');
                }
                if data.len() + value.len() > 65536 {
                    return Err(Error::Invalid("SSE event bound"));
                }
                data.extend_from_slice(value);
            } else if !line.starts_with(b"id:")
                && !line.starts_with(b"retry:")
                && line != b"event: message"
            {
                return Err(Error::Invalid("unsupported SSE event field"));
            }
        }
    }
    fn line(&mut self) -> Result<Vec<u8>> {
        let mut line = Vec::new();
        loop {
            let buffer = self
                .input
                .fill_buf()
                .map_err(|_| Error::Conflict("provider stream interrupted"))?;
            if buffer.is_empty() {
                return Err(Error::Conflict("SSE ended without DONE"));
            }
            let count = buffer
                .iter()
                .position(|b| *b == b'\n')
                .map_or(buffer.len(), |i| i + 1);
            if line.len() + count > 65536 || self.bytes + count > 4 * 1024 * 1024 {
                return Err(Error::Invalid("provider stream byte bound"));
            }
            let ended = buffer[count - 1] == b'\n';
            line.extend_from_slice(&buffer[..count]);
            self.bytes += count;
            self.input.consume(count);
            if ended {
                line.pop();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                return Ok(line);
            }
        }
    }
    fn chunk(&mut self, data: &[u8]) -> Result<ProviderEvent> {
        self.events += 1;
        if self.events > 4095 {
            return Err(Error::Invalid("provider event bound"));
        }
        let chunk: serde_json::Value = weaver_contracts::decode(data)?;
        if chunk.get("object").and_then(|v| v.as_str()) != Some("chat.completion.chunk")
            || chunk.get("model").and_then(|v| v.as_str()) != Some(&self.model)
        {
            return Err(Error::Invalid("provider model or response mode changed"));
        }
        let id = chunk
            .get("id")
            .and_then(|v| v.as_str())
            .filter(|v| !v.is_empty() && v.len() <= 256)
            .ok_or(Error::Invalid("provider stream id"))?;
        if self.id.as_deref().is_some_and(|original| original != id) {
            return Err(Error::Invalid("provider stream identity changed"));
        }
        self.id = Some(id.into());
        let choices = chunk
            .get("choices")
            .and_then(|v| v.as_array())
            .ok_or(Error::Invalid("provider choices"))?;
        if choices.is_empty() {
            return self.usage(&chunk);
        }
        if choices.len() != 1
            || self.finished
            || choices[0].get("index").and_then(|v| v.as_u64()) != Some(0)
        {
            return Err(Error::Invalid("provider choice order"));
        }
        let choice = &choices[0];
        let delta = choice
            .get("delta")
            .and_then(|v| v.as_object())
            .ok_or(Error::Invalid("provider delta"))?;
        if delta
            .keys()
            .any(|key| !matches!(key.as_str(), "role" | "content" | "refusal"))
        {
            return Err(Error::Invalid("tool or unsupported delta"));
        }
        if delta
            .get("role")
            .is_some_and(|v| v.as_str() != Some("assistant"))
        {
            return Err(Error::Invalid("provider role"));
        }
        let mut text = String::new();
        for key in ["content", "refusal"] {
            if let Some(value) = delta.get(key).filter(|v| !v.is_null()) {
                text.push_str(
                    value
                        .as_str()
                        .ok_or(Error::Invalid("provider text delta"))?,
                );
            }
        }
        let reason = choice.get("finish_reason").filter(|v| !v.is_null());
        if let Some(reason) = reason {
            if !matches!(reason.as_str(), Some("stop" | "length" | "content_filter")) {
                return Err(Error::Invalid("unadmitted finish reason"));
            }
            self.finished = true;
            // Keep content even if this provider puts its final text in the finish chunk.
            return Ok(ProviderEvent {
                sequence: 0,
                kind: ProviderEventKind::Finish,
                text,
                tokens: 0,
            });
        }
        Ok(ProviderEvent {
            sequence: 0,
            kind: ProviderEventKind::Delta,
            text,
            tokens: 0,
        })
    }
    fn usage(&mut self, chunk: &serde_json::Value) -> Result<ProviderEvent> {
        if !self.finished || self.usage {
            return Err(Error::Invalid("provider usage order"));
        }
        let count = chunk
            .get("usage")
            .and_then(|v| v.get("total_tokens"))
            .and_then(|v| v.as_u64())
            .filter(|n| *n <= i64::MAX as u64)
            .ok_or(Error::Invalid("provider usage"))?;
        self.usage = true;
        Ok(ProviderEvent {
            sequence: 0,
            kind: ProviderEventKind::Usage,
            text: String::new(),
            tokens: count,
        })
    }
}
