//! Bounded local telemetry with no execution, storage or transport capability.
#![forbid(unsafe_code)]
mod metrics;
pub use metrics::{Metrics, Signal, Snapshot};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
