// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Direct, asynchronous model calls with caller-selected endpoints.
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

pub use client::{Authentication, Client, Endpoint, EventStream};
pub use config::{Configuration, PreparedProfile};
pub use embeddings::{EmbeddingInput, EmbeddingRequest, EmbeddingUsage, Embeddings};
pub use error::Error;
pub use images::{ImageInput, ImageMediaType};
pub use operation::PreparedOperation;
pub use protocol::{
    Completion, CompletionChoice, Message, Options, Protocol, Request, ResponseFormat, Role, Tool,
    ToolCall, ToolChoice, Usage,
};

pub use responses::ResponsesOutput;
pub use stream::{TurnEvent, TurnIdentity, TurnStream};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
