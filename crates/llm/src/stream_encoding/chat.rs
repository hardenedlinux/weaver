// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
use super::encoder::{TurnEncoder, usage};
use crate::{Error, Protocol, TokenCategories, TurnEvent, TurnObservation, Usage};
use serde_json::{Value, json};
impl TurnEncoder {
    pub(super) fn chat_delta(
        &mut self,
        delta: Value,
        reason: Option<&str>,
        reported: Option<&Option<Usage>>,
        categories: Option<TokenCategories>,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        let identity = self.identity.as_ref().ok_or(Error::Response)?;
        let mut value = json!({"id":identity.id,"object":"chat.completion.chunk","created":self.created_at,"model":identity.model,
            "choices":[{"index":0,"delta":delta,"finish_reason":reason}]});
        if let Some(reported) = reported {
            value["usage"] = usage(reported, categories, Protocol::OpenAi)?;
        }
        self.emit("", value, out)
    }
    pub(super) fn chat(
        &mut self,
        observation: &TurnObservation,
        categories: Option<TokenCategories>,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        match &observation.event {
            Some(TurnEvent::Text(text)) => {
                self.chat_delta(json!({"content":text}), None, None, None, out)?
            }
            Some(TurnEvent::Thinking(_)) => return Err(Error::Response),
            Some(TurnEvent::Finished {
                reason,
                identity,
                usage,
                tool_calls,
                responses_output,
                anthropic_output,
            }) => {
                self.terminal_identity(identity)?;
                if responses_output.is_some() || anthropic_output.is_some() {
                    return Err(Error::Response);
                }
                if !tool_calls.is_empty() {
                    let calls:Vec<_>=tool_calls.iter().enumerate().map(|(index,c)|json!({"index":index,"id":c.id,"type":"function","function":{"name":c.name,"arguments":c.arguments.to_string()}})).collect();
                    self.chat_delta(json!({"tool_calls":calls}), None, None, None, out)?;
                }
                self.chat_delta(json!({}), Some(reason), Some(usage), categories, out)?;
                self.append(b"data: [DONE]\n\n", out)?;
            }
            None => {}
        }
        Ok(())
    }
}
