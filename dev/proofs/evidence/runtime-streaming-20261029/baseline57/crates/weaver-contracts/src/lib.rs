//! Canonical proposal boundary; records carry no execution authority.
mod json;
mod model;
pub use json::decode;
pub use model::{
    Error, MAX_BODY_BYTES, MAX_CREDITS, Outcome, Proposal, Receipt, Result, Task, body_digest,
    identifier,
};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
