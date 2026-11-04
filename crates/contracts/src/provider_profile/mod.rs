// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source-owned, immutable provider semantics; construction grants no execution rights.
mod artifact;
mod messages;
mod request;
mod sampling;

pub use artifact::{CHAT_TEXT_SSE, ProviderProfile, ProviderRequestFacts};
