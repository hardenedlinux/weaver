// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One deciding MRR Data/Turso store: immutable logical keys, holds, queue, policy and fence.
//! Whole-image rollback and network filesystems remain outside this profile.
/// Trusted host persistence utilities backed only by MRR Data's Turso driver.
/// This is not a Gateway request surface or an authorization capability.
#[cfg(any(test, feature = "commit-observer"))]
pub mod persistence;
#[cfg(not(any(test, feature = "commit-observer")))]
mod persistence;
pub use persistence::{Journal, LedgerCustody, Timing, TransactionTimings};
#[cfg(test)]
extern crate self as weaver_ledger;
mod delta_registration;
mod domains;
mod execution_exposure;
mod hard_fact;
pub use hard_fact::FactPreparation;
mod exposure_manifest;
#[cfg(feature = "commit-observer")]
pub use exposure_manifest::use_prepared_manifest_programs;
mod metering;
mod metering_credentials;
mod provider;
mod provider_delivery;
#[cfg(feature = "commit-observer")]
pub use provider_delivery::DeliveryObservation;
pub use provider_delivery::{
    DeliveryCursor, DeliveryFrame, DeliveryInterval, DeliveryProducer, DeliveryWait,
    ProviderDelivery,
};
mod provider_catalog;
mod provider_routing;
pub use provider_catalog::ProviderCatalogProjection;
pub use provider_routing::ProviderOperationCut;
mod provider_oauth;
mod provider_oauth_witness;
mod provider_profiles;
mod provider_publication;
#[cfg(feature = "commit-observer")]
pub use provider_publication::use_locked_publication_review;
mod provider_quota;
mod provider_workflow;
mod provider_workflow_choice;
mod provider_workflow_nested;
pub use provider_workflow::{ProviderProgression, WorkflowObservation};
pub use provider_workflow_choice::WorkflowChoiceObservation;
pub use provider_workflow_nested::NestedObservation;
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
pub use provider::{
    MAX_PROVIDER_PREPARATION_RANGES, MAX_PROVIDER_PREPARATION_ROWS, ProviderDispatch,
    ProviderRelease,
};
#[cfg(feature = "commit-observer")]
pub use provider::{
    use_cached_release_programs, use_conservative_range_invalidation, use_early_admission_barrier,
    use_exclusive_provider_reads, use_full_lifecycle_invalidation, use_separate_release_reads,
};
mod store;
mod stream_catalog;
mod stream_custody;
mod stream_progress;
mod stream_ranges;
mod stream_state;
mod task_publication;
pub use store::{Dispatch, Ledger};
#[cfg(feature = "commit-observer")]
pub use store::ParkedProviderConnection;
pub(crate) use store::{db, integer};
pub use stream_custody::{StreamClaim, StreamOwner};
pub use stream_ranges::RangePermit;

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());

#[cfg(feature = "commit-observer")]
pub use task_origins::{use_locked_original_evidence, use_prepared_original_program};

#[cfg(feature = "commit-observer")]
pub use domains::use_fresh_provider_domain_plan;
