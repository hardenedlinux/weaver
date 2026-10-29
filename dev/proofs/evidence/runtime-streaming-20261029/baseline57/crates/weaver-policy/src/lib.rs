//! Cedar admission API for the final deciding owner.
mod authorize;
pub use authorize::{authorize, validate};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
