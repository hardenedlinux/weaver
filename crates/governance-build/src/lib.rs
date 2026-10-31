//! Compiler-owned governance graph assembly for Cargo; no runtime execution API.
mod application;
mod program;
mod stage;
pub use application::ProgramApplication;
pub use program::build_program;
pub use stage::staging_expression;
#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
#[cfg(test)]
#[path = "../tests/unit/paths.rs"]
mod path_tests;
