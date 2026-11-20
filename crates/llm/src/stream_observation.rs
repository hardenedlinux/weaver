// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Closed stream coordinates for transport adapters; no raw tool fragments.
use crate::{Error, Protocol, TurnEvent, TurnIdentity, Usage};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

#[derive(Default)]
pub(crate) struct ObservationState {
    items: BTreeMap<u64, ItemState>,
    started: bool,
}
struct ItemState {
    id: String,
    kind: TurnItemKind,
    parts: BTreeMap<u64, Sha256>,
}
impl ObservationState {
    pub(crate) fn observe(
        &mut self,
        protocol: Protocol,
        observation: &TurnObservation,
    ) -> Result<(), Error> {
        if protocol != Protocol::OpenAiResponses {
            return Ok(());
        }
        if let Some(metadata) = &observation.metadata {
            match &metadata.control {
                Some(TurnControl::Started) => {
                    if metadata.identity.is_none() {
                        return Err(Error::Response);
                    }
                    self.started = true;
                }
                Some(TurnControl::ResponsesItem { index, id, kind }) => {
                    if !self.started || *index != self.items.len() as u64 {
                        return Err(Error::Response);
                    }
                    self.items.insert(
                        *index,
                        ItemState {
                            id: id.clone(),
                            kind: *kind,
                            parts: BTreeMap::new(),
                        },
                    );
                }
                Some(TurnControl::ResponsesPart {
                    item_id,
                    output_index,
                    content_index,
                }) => {
                    let item = self.items.get_mut(output_index).ok_or(Error::Response)?;
                    if item.id != *item_id
                        || item.kind != TurnItemKind::Message
                        || *content_index != item.parts.len() as u64
                    {
                        return Err(Error::Response);
                    }
                    item.parts.insert(*content_index, Sha256::new());
                }
                _ => {}
            }
        }
        if let Some(TurnEvent::Text(text)) = &observation.event {
            let Some(TurnMetadata {
                position:
                    Some(TurnPosition::Responses {
                        item_id,
                        output_index,
                        content_index,
                    }),
                ..
            }) = &observation.metadata
            else {
                return Err(Error::Response);
            };
            let item = self.items.get_mut(output_index).ok_or(Error::Response)?;
            if item.id != *item_id {
                return Err(Error::Response);
            }
            item.parts
                .get_mut(content_index)
                .ok_or(Error::Response)?
                .update(text.as_bytes());
        }
        if let Some(TurnEvent::Finished {
            responses_output: Some(output),
            ..
        }) = &observation.event
        {
            if !self.started || output.items().len() != self.items.len() {
                return Err(Error::Response);
            }
            output
                .items()
                .iter()
                .enumerate()
                .try_for_each(|(index, value)| {
                    self.items
                        .get(&(index as u64))
                        .ok_or(Error::Response)?
                        .require_final(value)
                })?;
        }
        Ok(())
    }
}

impl ItemState {
    fn require_final(&self, value: &Value) -> Result<(), Error> {
        let kind = match self.kind {
            TurnItemKind::Message => "message",
            TurnItemKind::Reasoning => "reasoning",
            TurnItemKind::FunctionCall => "function_call",
        };
        if value["id"] != self.id || value["type"] != kind {
            return Err(Error::Response);
        }
        if self.kind != TurnItemKind::Message {
            return Ok(());
        }
        let content = value["content"].as_array().ok_or(Error::Response)?;
        if value["role"] != "assistant" || content.len() != self.parts.len() {
            return Err(Error::Response);
        }
        content.iter().enumerate().try_for_each(|(index, part)| {
            let expected = self
                .parts
                .get(&(index as u64))
                .ok_or(Error::Response)?
                .clone()
                .finalize();
            let observed = Sha256::digest(part["text"].as_str().ok_or(Error::Response)?.as_bytes());
            if expected == observed {
                Ok(())
            } else {
                Err(Error::Response)
            }
        })
    }
}

/// One validated frame's logical event and optional transport coordinates.
#[derive(Debug, PartialEq, Eq)]
pub struct TurnObservation {
    pub event: Option<TurnEvent>,
    pub metadata: Option<TurnMetadata>,
}

/// Data needed to reconstruct standard SSE without guessing content indices.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnMetadata {
    pub identity: Option<TurnIdentity>,
    pub usage: Option<Usage>,
    pub position: Option<TurnPosition>,
    pub control: Option<TurnControl>,
}

/// The provider's content coordinates, without inferred indices or tool data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TurnPosition {
    Responses {
        item_id: String,
        output_index: u64,
        content_index: u64,
    },
    Anthropic {
        index: u64,
    },
}

/// Closed Responses item categories used for ordering, never tool execution.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TurnItemKind {
    Message,
    Reasoning,
    FunctionCall,
}

/// Closed Anthropic block categories; opaque blocks stay in terminal output.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TurnBlockKind {
    Text,
    Thinking,
    RedactedThinking,
    Tool,
}

/// Inert control data. Partial function arguments are never present here.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TurnControl {
    Started,
    ResponsesItem {
        index: u64,
        id: String,
        kind: TurnItemKind,
    },
    ResponsesPart {
        item_id: String,
        output_index: u64,
        content_index: u64,
    },
    AnthropicStart {
        index: u64,
        kind: TurnBlockKind,
    },
    AnthropicStop {
        index: u64,
        kind: TurnBlockKind,
        signature: Option<String>,
    },
}

pub(crate) fn text(value: &Value) -> Result<String, Error> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 1024)
        .map(str::to_owned)
        .ok_or(Error::Response)
}
fn index(value: &Value) -> Result<u64, Error> {
    value.as_u64().filter(|i| *i < 64).ok_or(Error::Response)
}
pub(crate) fn block_kind(value: &Value) -> Result<TurnBlockKind, Error> {
    match value.as_str() {
        Some("text") => Ok(TurnBlockKind::Text),
        Some("thinking") => Ok(TurnBlockKind::Thinking),
        Some("redacted_thinking") => Ok(TurnBlockKind::RedactedThinking),
        Some("tool_use") => Ok(TurnBlockKind::Tool),
        _ => Err(Error::Response),
    }
}

pub(crate) fn project(protocol: Protocol, value: &Value) -> Result<Option<TurnMetadata>, Error> {
    let mut metadata = TurnMetadata {
        identity: None,
        usage: None,
        position: None,
        control: None,
    };
    match (protocol, value["type"].as_str()) {
        (Protocol::OpenAiResponses, Some("response.created" | "response.in_progress"))
            if value["response"]["id"].is_string() && value["response"]["model"].is_string() =>
        {
            metadata.control = Some(TurnControl::Started);
        }
        (Protocol::OpenAiResponses, Some("response.output_item.added")) => {
            let kind = match value["item"]["type"].as_str() {
                Some("message") if value["item"]["role"] == "assistant" => TurnItemKind::Message,
                Some("reasoning") => TurnItemKind::Reasoning,
                Some("function_call") => TurnItemKind::FunctionCall,
                _ => return Err(Error::Response),
            };
            metadata.control = Some(TurnControl::ResponsesItem {
                index: index(&value["output_index"])?,
                id: text(&value["item"]["id"])?,
                kind,
            });
        }
        (Protocol::OpenAiResponses, Some("response.content_part.added"))
            if value["part"]["type"] == "output_text" =>
        {
            metadata.control = Some(TurnControl::ResponsesPart {
                item_id: text(&value["item_id"])?,
                output_index: index(&value["output_index"])?,
                content_index: index(&value["content_index"])?,
            });
        }
        (Protocol::OpenAiResponses, Some("response.output_text.delta")) => {
            metadata.position = Some(TurnPosition::Responses {
                item_id: text(&value["item_id"])?,
                output_index: index(&value["output_index"])?,
                content_index: index(&value["content_index"])?,
            });
        }
        (Protocol::Anthropic, Some("message_start")) => {
            metadata.control = Some(TurnControl::Started)
        }
        (Protocol::Anthropic, Some("content_block_start")) => {
            let i = index(&value["index"])?;
            metadata.control = Some(TurnControl::AnthropicStart {
                index: i,
                kind: block_kind(&value["content_block"]["type"])?,
            });
            metadata.position = Some(TurnPosition::Anthropic { index: i });
        }
        (Protocol::Anthropic, Some("content_block_delta" | "content_block_stop")) => {
            metadata.position = Some(TurnPosition::Anthropic {
                index: index(&value["index"])?,
            });
        }
        _ => {}
    }
    Ok((metadata.control.is_some() || metadata.position.is_some()).then_some(metadata))
}

#[cfg(test)]
#[path = "../tests/unit/stream_observation.rs"]
mod tests;
