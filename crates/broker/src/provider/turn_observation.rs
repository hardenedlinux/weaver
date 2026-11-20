// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Structural projection only; codec validates protocol, ledger owns release.
use weaver_contracts::{
    ProviderTurnBlockKind as Block, ProviderTurnControl as Control, ProviderTurnIdentity,
    ProviderTurnItemKind as Item, ProviderTurnMetadata, ProviderTurnPosition as Position,
    ProviderTurnUsage,
};
use weaver_llm::{TurnBlockKind, TurnControl, TurnItemKind, TurnMetadata, TurnPosition};

pub(super) fn project(metadata: TurnMetadata) -> ProviderTurnMetadata {
    ProviderTurnMetadata {
        identity: metadata.identity.map(|i| ProviderTurnIdentity {
            id: i.id,
            model: i.model,
        }),
        usage: metadata.usage.map(|u| ProviderTurnUsage {
            input_tokens: u.input_tokens,
            output_tokens: u.output_tokens,
            categories: None,
        }),
        position: metadata.position.map(|p| match p {
            TurnPosition::Responses {
                item_id,
                output_index,
                content_index,
            } => Position::Responses {
                item_id,
                output_index,
                content_index,
            },
            TurnPosition::Anthropic { index } => Position::Anthropic { index },
        }),
        control: metadata.control.map(|c| match c {
            TurnControl::Started => Control::Started,
            TurnControl::ResponsesItem { index, id, kind } => Control::ResponsesItem {
                index,
                id,
                item_kind: match kind {
                    TurnItemKind::Message => Item::Message,
                    TurnItemKind::Reasoning => Item::Reasoning,
                    TurnItemKind::FunctionCall => Item::FunctionCall,
                },
            },
            TurnControl::ResponsesPart {
                item_id,
                output_index,
                content_index,
            } => Control::ResponsesPart {
                item_id,
                output_index,
                content_index,
            },
            TurnControl::AnthropicStart { index, kind } => Control::AnthropicStart {
                index,
                block_kind: block(kind),
            },
            TurnControl::AnthropicStop {
                index,
                kind,
                signature,
            } => Control::AnthropicStop {
                index,
                block_kind: block(kind),
                signature,
            },
        }),
    }
}

fn block(kind: TurnBlockKind) -> Block {
    match kind {
        TurnBlockKind::Text => Block::Text,
        TurnBlockKind::Thinking => Block::Thinking,
        TurnBlockKind::RedactedThinking => Block::RedactedThinking,
        TurnBlockKind::Tool => Block::Tool,
    }
}
