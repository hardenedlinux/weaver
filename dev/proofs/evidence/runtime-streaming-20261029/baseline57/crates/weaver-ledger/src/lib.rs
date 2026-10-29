//! One deciding SQLite store: immutable logical keys, holds, queue, policy and fence.
//! Snapshot rollback and multi-host SQLite filesystems are outside this profile.
mod schema;
mod store;
pub use store::{Dispatch, Ledger};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
