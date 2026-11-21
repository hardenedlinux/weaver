// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
use super::encoder::{TurnEncoder, usage as encode_usage};
use crate::{
    Error, Protocol, TokenCategories, TurnBlockKind, TurnControl, TurnEvent, TurnObservation,
    TurnPosition,
};
use serde_json::{Value, json};
impl TurnEncoder {
    pub(super) fn messages(
        &mut self,
        observation: &TurnObservation,
        categories: Option<TokenCategories>,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        if let Some(metadata) = &observation.metadata {
            match &metadata.control {
                Some(TurnControl::AnthropicStart {index,kind}) if self.barrier.is_none()=>{
                    match kind {
                        TurnBlockKind::Tool|TurnBlockKind::RedactedThinking=>self.barrier=Some(*index),
                        TurnBlockKind::Text=>self.emit("content_block_start",json!({"index":index,"content_block":{"type":"text","text":""}}),out)?,
                        TurnBlockKind::Thinking=>self.emit("content_block_start",json!({"index":index,"content_block":{"type":"thinking","thinking":"","signature":""}}),out)?,
                    }
                },
                Some(TurnControl::AnthropicStop {index,kind,signature}) if self.barrier.is_none()=>{
                    if *kind==TurnBlockKind::Thinking && signature.as_ref().is_none_or(|s|s.is_empty()) {return Err(Error::Response);}
                    if let Some(signature)=signature {self.emit("content_block_delta",json!({"index":index,"delta":{"type":"signature_delta","signature":signature}}),out)?;}
                    self.emit("content_block_stop",json!({"index":index}),out)?;
                    self.closed_blocks+=1;
                },
                _=>{},
            }
        }
        match &observation.event {
            Some(TurnEvent::Text(text)) if self.barrier.is_none() => {
                self.message_delta(observation, "text_delta", "text", text, out)?
            }
            Some(TurnEvent::Thinking(text)) if self.barrier.is_none() => self.message_delta(
                observation,
                "thinking_delta",
                "thinking",
                text.as_str(),
                out,
            )?,
            Some(TurnEvent::Finished {
                reason,
                identity,
                usage,
                anthropic_output,
                responses_output,
                ..
            }) => {
                self.terminal_identity(identity)?;
                if responses_output.is_some() {
                    return Err(Error::Response);
                }
                let blocks = anthropic_output.as_ref().ok_or(Error::Response)?.items();
                let first = self.barrier.map_or(self.closed_blocks, |n| n as usize);
                if first > blocks.len() {
                    return Err(Error::Response);
                }
                for (index, block) in blocks.iter().enumerate().skip(first) {
                    self.message_block(index, block, out)?;
                }
                let mut end = json!({"delta":{"stop_reason":reason,"stop_sequence":null}});
                let reported = encode_usage(usage, categories, Protocol::Anthropic)?;
                if !reported.is_null() {
                    end["usage"] = reported;
                }
                self.emit("message_delta", end, out)?;
                self.emit("message_stop", json!({}), out)?;
            }
            _ => {}
        }
        Ok(())
    }
    fn message_delta(
        &mut self,
        observation: &TurnObservation,
        kind: &str,
        key: &str,
        text: &str,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        let Some(TurnPosition::Anthropic { index }) = observation
            .metadata
            .as_ref()
            .and_then(|m| m.position.as_ref())
        else {
            return Err(Error::Response);
        };
        let mut delta = json!({"type":kind});
        delta[key] = json!(text);
        self.emit(
            "content_block_delta",
            json!({"index":index,"delta":delta}),
            out,
        )
    }
    fn message_block(
        &mut self,
        index: usize,
        block: &Value,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        let mut header = block.clone();
        let delta = match block["type"].as_str() {
            Some("text") => {
                header["text"] = json!("");
                Some(json!({"type":"text_delta","text":block["text"]}))
            }
            Some("thinking") => {
                header["thinking"] = json!("");
                if block["signature"].as_str().is_none_or(|s| s.is_empty()) {
                    return Err(Error::Response);
                }
                header["signature"] = json!("");
                Some(json!({"type":"thinking_delta","thinking":block["thinking"]}))
            }
            Some("tool_use") => {
                header["input"] = json!({});
                Some(json!({"type":"input_json_delta","partial_json":block["input"].to_string()}))
            }
            Some("redacted_thinking") => None,
            _ => return Err(Error::Response),
        };
        self.emit(
            "content_block_start",
            json!({"index":index,"content_block":header}),
            out,
        )?;
        if let Some(delta) = delta {
            self.emit(
                "content_block_delta",
                json!({"index":index,"delta":delta}),
                out,
            )?;
        }
        if let Some(signature) = block.get("signature") {
            self.emit(
                "content_block_delta",
                json!({"index":index,"delta":{"type":"signature_delta","signature":signature}}),
                out,
            )?;
        }
        self.emit("content_block_stop", json!({"index":index}), out)
    }
}
