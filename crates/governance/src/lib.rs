// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Owned semantic source data. No method publishes, consumes, sends or refunds.
#![deny(unsafe_code)]
extern crate self as weaver_governance;
mod binding;
mod catalog;
mod hard_fact;
mod host;
mod source;
pub use binding::{BoundSource, SourceExpectation};
pub use catalog::{ApprovedProducer, CatalogError, ProducerCatalog, ProducerClient};
pub use hard_fact::derive_fact_impact;
pub use host::{SourceClient, SourceInbox, SourceJob, SourceJobError, source_lane};
pub use source::{MAX_SOURCE_BYTES, OwnedSource, SourceData, SourceError, SourceSelection};

#[cfg(feature = "scheme-vm")]
mod scheme;
#[cfg(feature = "scheme-vm")]
mod scheme_input;
#[cfg(feature = "scheme-vm")]
pub use scheme::materialize_bound_source;
#[cfg(feature = "scheme-vm")]
pub use scheme::materialize_source;
#[cfg(feature = "scheme-vm")]
pub use scheme_input::root_source;

#[cfg(feature = "scheme-program")]
mod program;
#[cfg(feature = "scheme-program")]
pub use program::SchemeCompiler;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());

#[cfg(test)]
#[path = "../tests/unit/binding.rs"]
mod binding_tests;
#[cfg(test)]
#[path = "../tests/unit/fixture.rs"]
mod source_fixture;
#[cfg(test)]
#[path = "../tests/unit/source.rs"]
mod source_tests;

#[cfg(test)]
#[path = "../tests/unit/catalog.rs"]
mod catalog_tests;
#[cfg(test)]
#[path = "../tests/unit/configuration.rs"]
mod configuration_tests;
#[cfg(test)]
#[path = "../tests/unit/host.rs"]
mod host_tests;
