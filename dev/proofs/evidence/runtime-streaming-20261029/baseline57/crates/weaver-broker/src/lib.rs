//! Final transport owner. Go never receives a network-capable dispatch token.
mod https;
pub use https::{HttpsTransport, SendObservation};
mod execute;
pub use execute::execute;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
