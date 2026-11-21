// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Per-response SSE preparation; `ProviderOutput` retains the guarded handoff.
use weaver_contracts::{Error, ProviderEvent, ProviderEventKind, ProviderRoute, Result};
use weaver_llm::{Protocol, TurnEncoder};

/// One response's encoding state. Preparation returns inert bytes and never
/// obtains a permit, publishes data, resolves credentials or retries requests.
pub struct ProviderSseEncoder {
    encoder: TurnEncoder,
    model: String,
    route: Option<ProviderRoute>,
    next: u64,
    closed: bool,
}
impl ProviderSseEncoder {
    /// Use the source-selected rich protocol/model and cumulative output budget.
    ///
    /// # Errors
    /// Rejects unsupported protocols/models or an invalid SDK output budget.
    pub fn new(protocol: &str, model: &str, limit: usize, created_at: u64) -> Result<Self> {
        let protocol = match protocol {
            weaver_contracts::CHAT_TURN_SSE => Protocol::OpenAi,
            weaver_contracts::RESPONSES_TURN_SSE => Protocol::OpenAiResponses,
            weaver_contracts::ANTHROPIC_TURN_SSE => Protocol::Anthropic,
            _ => return Err(Error::Invalid("SSE source protocol")),
        };
        if model.is_empty() || model.len() > 1024 {
            return Err(Error::Invalid("SSE source model"));
        }
        let encoder = TurnEncoder::new(protocol, limit, created_at)
            .map_err(|_| Error::Invalid("SSE output budget"))?;
        Ok(Self {
            encoder,
            model: model.into(),
            route: None,
            next: 0,
            closed: false,
        })
    }

    /// Prepare already validated broker observations before final ledger release.
    /// The same response requires one route/model and a contiguous original
    /// sequence. No committed RPC bytes are translated and no protocol is parsed
    /// again. A failed batch returns no partial bytes and closes this projection.
    ///
    /// # Errors
    /// Rejects rebinding, replay, legacy mixed events, encoding errors or limits.
    pub fn prepare(
        &mut self,
        route: &ProviderRoute,
        model: &str,
        events: &[ProviderEvent],
    ) -> Result<Vec<u8>> {
        if self.closed {
            return Err(Error::Conflict("SSE projection closed"));
        }
        let result = self.prepare_batch(route, model, events);
        if result.is_err() {
            self.abort();
        }
        result
    }

    /// Discard projection state after cancellation or a rejected response. This
    /// does not undo already released bytes or restore the original reservation.
    pub fn abort(&mut self) {
        self.closed = true;
        self.encoder.abort();
    }

    fn prepare_batch(
        &mut self,
        route: &ProviderRoute,
        model: &str,
        events: &[ProviderEvent],
    ) -> Result<Vec<u8>> {
        if model != self.model
            || self.route.as_ref().is_some_and(|old| old != route)
            || events.is_empty()
            || events.len() > 32
        {
            return Err(Error::Invalid("SSE response binding"));
        }
        if self.route.is_none() {
            self.route = Some(route.clone());
        }
        let mut output = Vec::new();
        for event in events {
            if event.sequence != self.next || !event.text.is_empty() || event.tokens != 0 {
                return Err(Error::Invalid("SSE observation sequence"));
            }
            let ProviderEventKind::Turn(turn) = &event.kind else {
                return Err(Error::Invalid("SSE rich observation required"));
            };
            if turn.version != 1 {
                return Err(Error::Invalid("SSE observation version"));
            }
            if turn
                .metadata
                .as_ref()
                .and_then(|m| m.identity.as_ref())
                .is_some_and(|identity| identity.model != self.model)
            {
                return Err(Error::Invalid("SSE provider model binding"));
            }
            let (observation, categories) = super::observation::project(turn)?;
            let bytes = self
                .encoder
                .push(&observation, categories)
                .map_err(|_| Error::Invalid("SSE protocol projection"))?;
            output.extend_from_slice(&bytes);
            self.next = self
                .next
                .checked_add(1)
                .ok_or(Error::Invalid("SSE sequence overflow"))?;
        }
        Ok(output)
    }
}
