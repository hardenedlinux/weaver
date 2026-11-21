// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
use super::encoder::{TurnEncoder, usage as encode_usage};
use crate::{
    Error, Protocol, TokenCategories, TurnControl, TurnEvent, TurnItemKind, TurnObservation,
    TurnPosition,
};
use serde_json::{Value, json};
impl TurnEncoder {
    fn visible(&self, index: u64) -> bool {
        self.barrier.is_none_or(|barrier| index < barrier)
    }
    pub(super) fn responses(
        &mut self,
        observation: &TurnObservation,
        categories: Option<TokenCategories>,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        if let Some(metadata) = &observation.metadata {
            match &metadata.control {
                Some(TurnControl::ResponsesItem {index,id,kind}) if self.visible(*index)=>{
                    match kind {
                        TurnItemKind::FunctionCall=>self.barrier=Some(*index),
                        TurnItemKind::Message=>self.emit("response.output_item.added",json!({"output_index":index,"item":{"id":id,"type":"message","role":"assistant","status":"in_progress","content":[]}}),out)?,
                        TurnItemKind::Reasoning=>self.emit("response.output_item.added",json!({"output_index":index,"item":{"id":id,"type":"reasoning","summary":[]}}),out)?,
                    }
                },
                Some(TurnControl::ResponsesPart {item_id,output_index,content_index}) if self.visible(*output_index)=>{
                    self.emit("response.content_part.added",json!({"item_id":item_id,"output_index":output_index,"content_index":content_index,"part":{"type":"output_text","text":"","annotations":[]}}),out)?;
                },
                _=>{},
            }
        }
        match &observation.event {
            Some(TurnEvent::Text(text)) => {
                let Some(TurnPosition::Responses {
                    item_id,
                    output_index,
                    content_index,
                }) = observation
                    .metadata
                    .as_ref()
                    .and_then(|m| m.position.as_ref())
                else {
                    return Err(Error::Response);
                };
                if self.visible(*output_index) {
                    self.emit("response.output_text.delta",json!({"item_id":item_id,"output_index":output_index,"content_index":content_index,"delta":text}),out)?;
                }
            }
            Some(TurnEvent::Thinking(_)) => return Err(Error::Response),
            Some(TurnEvent::Finished {
                identity,
                usage,
                responses_output,
                anthropic_output,
                ..
            }) => {
                self.terminal_identity(identity)?;
                if anthropic_output.is_some() {
                    return Err(Error::Response);
                }
                let items = responses_output.as_ref().ok_or(Error::Response)?.items();
                for (index, item) in items.iter().enumerate() {
                    self.response_item(index, item, !self.visible(index as u64), out)?;
                }
                let value = self.response(
                    "completed",
                    json!(items),
                    encode_usage(usage, categories, Protocol::OpenAiResponses)?,
                )?;
                self.emit("response.completed", json!({"response":value}), out)?;
            }
            None => {}
        }
        Ok(())
    }
    fn response_item(
        &mut self,
        index: usize,
        item: &Value,
        replay: bool,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        if replay {
            let mut header = item.clone();
            match item["type"].as_str() {
                Some("message") => {
                    header["content"] = json!([]);
                    header["status"] = json!("in_progress");
                }
                Some("reasoning") => header["summary"] = json!([]),
                Some("function_call") => {
                    header["arguments"] = json!("");
                    header["status"] = json!("in_progress");
                }
                _ => return Err(Error::Response),
            }
            self.emit(
                "response.output_item.added",
                json!({"output_index":index,"item":header}),
                out,
            )?;
        }
        match item["type"].as_str() {
            Some("message") => {
                let parts = item["content"].as_array().ok_or(Error::Response)?;
                for (part_index, part) in parts.iter().enumerate() {
                    self.response_part(index, &item["id"], part_index, part, replay, out)?;
                }
            }
            Some("reasoning") => self.reasoning_parts(index, item, out)?,
            Some("function_call") => {
                if !replay {
                    return Err(Error::Response);
                }
                let args = item["arguments"].as_str().ok_or(Error::Response)?;
                self.emit(
                    "response.function_call_arguments.delta",
                    json!({"item_id":item["id"],"output_index":index,"delta":args}),
                    out,
                )?;
                self.emit(
                    "response.function_call_arguments.done",
                    json!({"item_id":item["id"],"output_index":index,"arguments":args}),
                    out,
                )?;
            }
            _ => return Err(Error::Response),
        }
        self.emit(
            "response.output_item.done",
            json!({"output_index":index,"item":item}),
            out,
        )
    }
    fn response_part(
        &mut self,
        index: usize,
        id: &Value,
        part_index: usize,
        part: &Value,
        replay: bool,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        let text = part["text"].as_str().ok_or(Error::Response)?;
        let mut fields = json!({"item_id":id,"output_index":index,"content_index":part_index});
        if replay {
            fields["part"] = json!({"type":"output_text","text":"","annotations":[]});
            self.emit("response.content_part.added", fields.clone(), out)?;
            fields
                .as_object_mut()
                .ok_or(Error::Response)?
                .remove("part");
            fields["delta"] = json!(text);
            self.emit("response.output_text.delta", fields.clone(), out)?;
            fields
                .as_object_mut()
                .ok_or(Error::Response)?
                .remove("delta");
        }
        if let Some(notes) = part.get("annotations").and_then(Value::as_array) {
            for (note, annotation) in notes.iter().enumerate() {
                let mut event = fields.clone();
                event["annotation_index"] = json!(note);
                event["annotation"] = annotation.clone();
                self.emit("response.output_text.annotation.added", event, out)?;
            }
        }
        fields["text"] = json!(text);
        self.emit("response.output_text.done", fields.clone(), out)?;
        fields
            .as_object_mut()
            .ok_or(Error::Response)?
            .remove("text");
        fields["part"] = part.clone();
        self.emit("response.content_part.done", fields, out)
    }
    fn reasoning_parts(
        &mut self,
        index: usize,
        item: &Value,
        out: &mut Vec<u8>,
    ) -> Result<(), Error> {
        let parts = match item.get("summary") {
            None => return Ok(()),
            Some(value) => value.as_array().ok_or(Error::Response)?,
        };
        for (part_index, part) in parts.iter().enumerate() {
            let text = part["text"].as_str().ok_or(Error::Response)?;
            let fields =
                json!({"item_id":item["id"],"output_index":index,"summary_index":part_index});
            let mut event = fields.clone();
            event["part"] = json!({"type":"summary_text","text":""});
            self.emit("response.reasoning_summary_part.added", event, out)?;
            let mut event = fields.clone();
            event["delta"] = json!(text);
            self.emit("response.reasoning_summary_text.delta", event, out)?;
            let mut event = fields.clone();
            event["text"] = json!(text);
            self.emit("response.reasoning_summary_text.done", event, out)?;
            let mut event = fields;
            event["part"] = part.clone();
            self.emit("response.reasoning_summary_part.done", event, out)?;
        }
        Ok(())
    }
}
