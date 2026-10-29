//! Trusted local command API; never mount as an agent-facing service.
mod commands;
mod stream_commands;
pub use commands::run;
#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
