//! Cedar admission API for the final deciding owner.
mod authorize;
mod compiled;
mod provider;
pub use provider::{BoundProviderPolicy, ProviderCheck, bind_provider};
mod stream;
mod typed;
pub use authorize::{authorize, validate};
pub use stream::{StreamCheck, authorize_stream};
pub use typed::validate_typed;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
