//! Owned semantic source data. No method publishes, consumes, sends or refunds.
#![forbid(unsafe_code)]
extern crate self as weaver_governance;
mod binding;
mod host;
mod source;
pub use binding::{BoundSource, SourceExpectation};
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
#[path = "../tests/unit/host.rs"]
mod host_tests;
