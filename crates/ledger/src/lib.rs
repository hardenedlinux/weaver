//! One deciding SQLite store: immutable logical keys, holds, queue, policy and fence.
//! Snapshot rollback and multi-host SQLite filesystems are outside this profile.
mod provider;
mod provider_profiles;
mod publication;
mod publication_barrier;
mod schema;
pub use provider::{ProviderDispatch, ProviderRelease};
mod store;
mod stream_catalog;
mod stream_custody;
mod stream_ranges;
mod stream_state;
mod task_publication;
pub use store::{Dispatch, Ledger};
pub use stream_custody::{StreamClaim, StreamOwner};
pub use stream_ranges::RangePermit;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
