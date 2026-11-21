// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source-owned, immutable provider semantics; construction grants no execution rights.
mod artifact;
mod messages;
mod request;
mod sampling;
mod turn_request;

pub use artifact::{
    ANTHROPIC_MESSAGES_SSE, ANTHROPIC_TURN_SSE, CHAT_TEXT_SSE, CHAT_TURN_SSE, ProviderProfile,
    ProviderProtocol, ProviderRequestFacts, RESPONSES_TURN_SSE,
};
