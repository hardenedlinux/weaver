// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Pure SSE projection; encoding never grants network or release authority.
mod chat;
mod encoder;
mod messages;
mod responses;
pub use encoder::TurnEncoder;

#[cfg(test)]
#[path = "../../tests/unit/stream_encoding.rs"]
mod tests;
