// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One deciding MRR Data/Turso store: immutable logical keys, holds, queue, policy and fence.
//! Whole-image rollback and network filesystems remain outside this profile.
/// Trusted host persistence utilities backed only by MRR Data's Turso driver.
/// This is not a Gateway request surface or an authorization capability.
pub mod persistence;
#[cfg(test)]
extern crate self as weaver_ledger;
mod delta_registration;
mod domains;
mod execution_exposure;
mod exposure_manifest;
mod metering;
mod metering_credentials;
mod provider;
mod provider_catalog;
mod provider_oauth;
mod provider_profiles;
mod provider_quota;
mod publication;
mod publication_barrier;
mod publication_review;
mod review_authority;
#[cfg(test)]
#[path = "../tests/unit/review_fixture.rs"]
mod review_fixture;
mod reviewed_head;
mod schema;
#[cfg(test)]
#[path = "../tests/unit/storage_snapshot.rs"]
mod snapshot;
mod source_authority;
mod source_rotation;
mod task_origins;
pub use provider::{ProviderDispatch, ProviderRelease};
mod store;
mod stream_catalog;
mod stream_custody;
mod stream_progress;
mod stream_ranges;
mod stream_state;
mod task_publication;
pub use store::{Dispatch, Ledger};
pub use stream_custody::{StreamClaim, StreamOwner};
pub use stream_ranges::RangePermit;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
