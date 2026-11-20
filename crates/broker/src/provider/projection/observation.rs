// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0
use weaver_contracts::{Error, ProviderTurnEvent, ProviderTurnPayload, Result};
use weaver_llm::{TokenCategories, ToolCall, TurnEvent, TurnIdentity, TurnObservation, Usage};

pub(super) fn project(
    turn: &ProviderTurnEvent,
) -> Result<(TurnObservation, Option<TokenCategories>)> {
    let mut categories = None;
    let event = match &turn.payload {
        ProviderTurnPayload::Control => None,
        ProviderTurnPayload::Text { text } => Some(TurnEvent::Text(text.clone())),
        ProviderTurnPayload::Thinking { text } => Some(TurnEvent::Thinking(text.clone().into())),
        ProviderTurnPayload::Finished {
            reason,
            identity,
            usage,
            tool_calls,
            responses_output,
            anthropic_output,
        } => {
            categories =
                usage
                    .as_ref()
                    .and_then(|u| u.categories.as_ref())
                    .map(|c| TokenCategories {
                        ordinary_input: c.ordinary_input,
                        cache_read_input: c.cache_read_input,
                        cache_write_input: c.cache_write_input,
                        output: c.output,
                    });
            Some(TurnEvent::Finished {
                reason: reason.clone(),
                identity: identity.as_ref().map(|i| TurnIdentity {
                    id: i.id.clone(),
                    model: i.model.clone(),
                }),
                usage: usage.as_ref().map(|u| Usage {
                    input_tokens: u.input_tokens,
                    output_tokens: u.output_tokens,
                }),
                tool_calls: tool_calls
                    .iter()
                    .map(|c| ToolCall {
                        id: c.id.clone(),
                        name: c.name.clone(),
                        arguments: c.arguments.clone(),
                    })
                    .collect(),
                responses_output: responses_output
                    .as_ref()
                    .map(|items| serde_json::from_value(serde_json::Value::Array(items.clone())))
                    .transpose()
                    .map_err(|_| Error::Invalid("Responses retained output"))?,
                anthropic_output: anthropic_output
                    .as_ref()
                    .map(|items| serde_json::from_value(serde_json::Value::Array(items.clone())))
                    .transpose()
                    .map_err(|_| Error::Invalid("Messages retained output"))?,
            })
        }
    };
    Ok((
        TurnObservation {
            event,
            metadata: turn.metadata.as_ref().map(super::metadata::project),
        },
        categories,
    ))
}
