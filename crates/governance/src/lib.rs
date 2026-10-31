//! Owned semantic source data. No method publishes, consumes, sends or refunds.
#![forbid(unsafe_code)]
extern crate self as weaver_governance;
mod source;
pub use source::{MAX_SOURCE_BYTES, OwnedSource, SourceData, SourceError, SourceSelection};

#[cfg(feature = "scheme-vm")]
mod scheme;
#[cfg(feature = "scheme-vm")]
pub use scheme::materialize_source;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());

#[cfg(test)]
#[path = "../tests/unit/source.rs"]
mod source_tests;
