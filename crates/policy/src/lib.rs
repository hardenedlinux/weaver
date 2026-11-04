// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Cedar admission API for the final deciding owner.
mod delta_review;
pub use delta_review::verify_delta_review;
mod authorize;
mod compiled;
mod provider;
mod provider_context;
pub use provider::{BoundProviderPolicy, ProviderCheck, bind_provider};
mod publication_replay;
mod stream;
mod typed;
pub use authorize::{authorize, validate};
pub use publication_replay::{PublicationReplayCheck, verify_publication_replay};
pub use stream::{StreamCheck, authorize_stream};
pub use typed::validate_typed;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());

#[cfg(test)]
#[path = "../tests/unit/provider_context.rs"]
mod provider_context_tests;

mod qualified_delta;
pub use qualified_delta::verify_qualified_delta;
