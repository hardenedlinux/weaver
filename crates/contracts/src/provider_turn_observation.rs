// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Inert, bounded coordinates carried through the existing release owner.
use super::{ProviderTurnIdentity, ProviderTurnUsage};
use serde::{Deserialize, Serialize};

/// Coordinates do not authorize tool execution, settlement or subsequent sends.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderTurnMetadata {
    pub identity: Option<ProviderTurnIdentity>,
    pub usage: Option<ProviderTurnUsage>,
    pub position: Option<ProviderTurnPosition>,
    pub control: Option<ProviderTurnControl>,
}

/// Provider positions, never indices inferred by an HTTP adapter.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "protocol", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProviderTurnPosition {
    Responses {
        item_id: String,
        output_index: u64,
        content_index: u64,
    },
    Anthropic {
        index: u64,
    },
}

/// Closed categories preserve order without publishing partial tool inputs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderTurnItemKind {
    Message,
    Reasoning,
    FunctionCall,
}

/// Opaque Messages blocks remain part of the final continuation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderTurnBlockKind {
    Text,
    Thinking,
    RedactedThinking,
    Tool,
}

/// Signatures become visible only after the matching block closes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProviderTurnControl {
    Started,
    ResponsesItem {
        index: u64,
        id: String,
        item_kind: ProviderTurnItemKind,
    },
    ResponsesPart {
        item_id: String,
        output_index: u64,
        content_index: u64,
    },
    AnthropicStart {
        index: u64,
        block_kind: ProviderTurnBlockKind,
    },
    AnthropicStop {
        index: u64,
        block_kind: ProviderTurnBlockKind,
        signature: Option<String>,
    },
}

impl std::fmt::Debug for ProviderTurnMetadata {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderTurnMetadata")
            .finish_non_exhaustive()
    }
}

impl ProviderTurnMetadata {
    pub(super) fn valid(&self) -> bool {
        let text = |s: &str| !s.is_empty() && s.len() <= 1024;
        let indices = |a: u64, b: u64| a < 64 && b < 64;
        self.identity
            .as_ref()
            .is_none_or(|id| text(&id.id) && text(&id.model))
            && self
                .usage
                .as_ref()
                .is_none_or(ProviderTurnUsage::consistent)
            && self.position.as_ref().is_none_or(|p| match p {
                ProviderTurnPosition::Responses {
                    item_id,
                    output_index,
                    content_index,
                } => text(item_id) && indices(*output_index, *content_index),
                ProviderTurnPosition::Anthropic { index } => *index < 64,
            })
            && self.control.as_ref().is_none_or(|c| match c {
                ProviderTurnControl::Started => self.identity.is_some(),
                ProviderTurnControl::ResponsesItem { index, id, .. } => *index < 64 && text(id),
                ProviderTurnControl::ResponsesPart {
                    item_id,
                    output_index,
                    content_index,
                } => text(item_id) && indices(*output_index, *content_index),
                ProviderTurnControl::AnthropicStart { index, .. } => *index < 64,
                ProviderTurnControl::AnthropicStop {
                    index,
                    block_kind,
                    signature,
                } => {
                    *index < 64
                        && signature.as_ref().is_none_or(|s| {
                            *block_kind == ProviderTurnBlockKind::Thinking && !s.is_empty()
                        })
                }
            })
            && (self.identity.is_some()
                || self.usage.is_some()
                || self.position.is_some()
                || self.control.is_some())
    }
}
