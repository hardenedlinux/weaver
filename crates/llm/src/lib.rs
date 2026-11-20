// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Direct, asynchronous model calls with caller-selected endpoints.
mod anthropic_output;
mod client;
mod config;
mod embeddings;
mod error;
mod files;
mod images;
pub mod oauth;
mod operation;
mod protocol;
mod responses;
mod stream;
mod stream_encoding;
pub use stream_encoding::TurnEncoder;
mod token_categories;
pub use token_categories::TokenCategories;

pub use anthropic_output::AnthropicOutput;
pub use client::{Authentication, Client, Endpoint, EventStream};
pub use config::{Configuration, PreparedProfile, ResolvedTarget, resolve_direct_target};
pub use embeddings::{EmbeddingInput, EmbeddingRequest, EmbeddingUsage, Embeddings};
pub use error::Error;
pub use images::{ImageInput, ImageMediaType};
pub use operation::PreparedOperation;
pub use protocol::{
    AnthropicEffort, AnthropicSettings, AnthropicThinking, Completion, CompletionChoice, Message,
    Options, Protocol, Request, ResponseFormat, Role, Tool, ToolCall, ToolChoice, Usage,
};

pub use responses::ResponsesOutput;
pub use stream::{ThinkingDelta, TurnDecoder, TurnEvent, TurnIdentity, TurnStream};
mod stream_observation;
pub use stream_observation::{
    TurnBlockKind, TurnControl, TurnItemKind, TurnMetadata, TurnObservation, TurnPosition,
};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
