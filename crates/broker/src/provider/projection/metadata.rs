// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
use weaver_contracts::{
    ProviderTurnBlockKind as Block, ProviderTurnControl as Control, ProviderTurnItemKind as Item,
    ProviderTurnMetadata, ProviderTurnPosition as Position,
};
use weaver_llm::{
    TurnBlockKind, TurnControl, TurnIdentity, TurnItemKind, TurnMetadata, TurnPosition, Usage,
};

pub(super) fn project(m: &ProviderTurnMetadata) -> TurnMetadata {
    TurnMetadata {
        identity: m.identity.as_ref().map(|i| TurnIdentity {
            id: i.id.clone(),
            model: i.model.clone(),
        }),
        usage: m.usage.as_ref().map(|u| Usage {
            input_tokens: u.input_tokens,
            output_tokens: u.output_tokens,
        }),
        position: m.position.as_ref().map(|p| match p {
            Position::Responses {
                item_id,
                output_index,
                content_index,
            } => TurnPosition::Responses {
                item_id: item_id.clone(),
                output_index: *output_index,
                content_index: *content_index,
            },
            Position::Anthropic { index } => TurnPosition::Anthropic { index: *index },
        }),
        control: m.control.as_ref().map(|c| match c {
            Control::Started => TurnControl::Started,
            Control::ResponsesItem {
                index,
                id,
                item_kind,
            } => TurnControl::ResponsesItem {
                index: *index,
                id: id.clone(),
                kind: match item_kind {
                    Item::Message => TurnItemKind::Message,
                    Item::Reasoning => TurnItemKind::Reasoning,
                    Item::FunctionCall => TurnItemKind::FunctionCall,
                },
            },
            Control::ResponsesPart {
                item_id,
                output_index,
                content_index,
            } => TurnControl::ResponsesPart {
                item_id: item_id.clone(),
                output_index: *output_index,
                content_index: *content_index,
            },
            Control::AnthropicStart { index, block_kind } => TurnControl::AnthropicStart {
                index: *index,
                kind: block(*block_kind),
            },
            Control::AnthropicStop {
                index,
                block_kind,
                signature,
            } => TurnControl::AnthropicStop {
                index: *index,
                kind: block(*block_kind),
                signature: signature.clone(),
            },
        }),
    }
}
fn block(kind: Block) -> TurnBlockKind {
    match kind {
        Block::Text => TurnBlockKind::Text,
        Block::Thinking => TurnBlockKind::Thinking,
        Block::RedactedThinking => TurnBlockKind::RedactedThinking,
        Block::Tool => TurnBlockKind::Tool,
    }
}
