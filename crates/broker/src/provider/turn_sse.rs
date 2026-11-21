// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Shared codec on the broker-owned, already consumed and guarded HTTP response.
use tokio::io::{AsyncRead, AsyncReadExt};
use weaver_contracts::{
    Error, ProviderEvent, ProviderEventKind, ProviderTokenCategories, ProviderToolCall,
    ProviderTurnEvent, ProviderTurnIdentity, ProviderTurnPayload, ProviderTurnUsage, Result,
};
use weaver_llm::{Protocol, TurnDecoder, TurnEvent};

#[path = "turn_observation.rs"]
mod observation;

pub(super) struct Decoder<R> {
    input: R,
    codec: TurnDecoder,
    model: String,
    terminal: bool,
    events: usize,
}

impl<R: AsyncRead + Unpin> Decoder<R> {
    pub(super) fn terminal_tokens(&self) -> Option<[u64; 4]> {
        if !self.terminal {
            return None;
        }
        self.codec.terminal_usage().map(|usage| {
            [
                usage.ordinary_input,
                usage.cache_read_input,
                usage.cache_write_input,
                usage.output,
            ]
        })
    }

    pub(super) fn new(input: R, model: &str, protocol: Protocol) -> Self {
        Self {
            input,
            codec: TurnDecoder::new(protocol, 4 * 1024 * 1024).with_expected_model(model.into()),
            model: model.into(),
            terminal: false,
            events: 0,
        }
    }

    pub(super) async fn next(&mut self) -> Result<ProviderEvent> {
        loop {
            tokio::task::consume_budget().await;
            if let Some(event) = self.next_buffered()? {
                return Ok(event);
            }
            if self.terminal {
                return Err(Error::Conflict("rich stream already complete"));
            }
            let mut bytes = [0; 4096];
            let count = self
                .input
                .read(&mut bytes)
                .await
                .map_err(|_| Error::Conflict("rich stream interrupted"))?;
            if count == 0 {
                self.codec
                    .finish()
                    .map_err(|_| Error::Conflict("rich stream incomplete"))?;
                return Err(Error::Conflict("rich stream ended"));
            }
            self.codec
                .push_bytes(&bytes[..count])
                .map_err(|_| Error::Invalid("rich stream byte limit"))?;
        }
    }

    pub(super) fn next_buffered(&mut self) -> Result<Option<ProviderEvent>> {
        let Some(observed) = self.next_observation()? else {
            return Ok(None);
        };
        let payload = match observed.event {
            None => ProviderTurnPayload::Control,
            Some(TurnEvent::Text(text)) => ProviderTurnPayload::Text { text },
            Some(TurnEvent::Thinking(text)) => ProviderTurnPayload::Thinking {
                text: text.as_str().into(),
            },
            Some(TurnEvent::Finished {
                reason,
                identity,
                usage,
                tool_calls,
                responses_output,
                anthropic_output,
            }) => {
                let identity = identity
                    .filter(|id| id.model == self.model)
                    .ok_or(Error::Invalid("rich terminal identity"))?;
                self.terminal = true;
                ProviderTurnPayload::Finished {
                    reason,
                    identity: Some(ProviderTurnIdentity {
                        id: identity.id,
                        model: identity.model,
                    }),
                    usage: usage.map(|u| ProviderTurnUsage {
                        input_tokens: u.input_tokens,
                        output_tokens: u.output_tokens,
                        categories: self
                            .codec
                            .terminal_usage()
                            .map(|c| ProviderTokenCategories {
                                ordinary_input: c.ordinary_input,
                                cache_read_input: c.cache_read_input,
                                cache_write_input: c.cache_write_input,
                                output: c.output,
                            }),
                    }),
                    tool_calls: tool_calls
                        .into_iter()
                        .map(|call| ProviderToolCall {
                            id: call.id,
                            name: call.name,
                            arguments: call.arguments,
                        })
                        .collect(),
                    responses_output: responses_output.map(|output| output.into_iter().collect()),
                    anthropic_output: anthropic_output.map(|output| output.into_iter().collect()),
                }
            }
        };
        let turn = ProviderTurnEvent {
            version: 1,
            metadata: observed.metadata.map(observation::project),
            payload,
        };
        turn.encode()?;
        Ok(Some(ProviderEvent {
            sequence: 0,
            kind: ProviderEventKind::Turn(Box::new(turn)),
            text: String::new(),
            tokens: 0,
        }))
    }

    fn next_observation(&mut self) -> Result<Option<weaver_llm::TurnObservation>> {
        while let Some(observed) = self
            .codec
            .next_observation()
            .map_err(|_| Error::Invalid("rich provider protocol"))?
        {
            self.events += 1;
            if self.events > 4096 {
                return Err(Error::Invalid("rich stream event limit"));
            }
            if observed
                .metadata
                .as_ref()
                .and_then(|m| m.identity.as_ref())
                .is_some_and(|identity| identity.model != self.model)
            {
                return Err(Error::Invalid("rich response identity"));
            }
            // A private argument/signature fragment has only a position. Drain
            // it locally; it neither needs a released frame nor authorizes work.
            if observed.event.is_some()
                || observed
                    .metadata
                    .as_ref()
                    .is_some_and(|m| m.control.is_some())
            {
                return Ok(Some(observed));
            }
        }
        Ok(None)
    }
}

#[cfg(test)]
#[path = "../../tests/unit/provider_turn_sse.rs"]
mod tests;
