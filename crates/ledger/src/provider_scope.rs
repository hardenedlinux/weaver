// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Provider scope write-set obligations and their observed comparison controls.

/// Sealed proof obligation for the two progress-only write paths in this module.
/// No external caller or other ledger module can construct this token.
/// Its transaction may only append fresh ranges/advance next_event, or CAS an
/// exact unknown release to released. All authorization inputs stay unchanged.
pub(crate) struct RangeProgress {
    pub(super) _sealed: (),
}
/// Unaccepted execution request. It cannot mutate shared facts or expose an
/// authoritative outcome before the scheduler selects its writer turn.
pub(crate) struct AdmissionRequest {
    pub(super) _sealed: (),
}
#[cfg(feature = "commit-observer")]
thread_local! {
    static EARLY_ADMISSION_BARRIER: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
/// Safe same-image control retaining closure while an admission request waits.
#[cfg(feature = "commit-observer")]
pub fn use_early_admission_barrier(early: bool) {
    EARLY_ADMISSION_BARRIER.set(early);
}
impl AdmissionRequest {
    pub(crate) fn wait_before_close(&self) -> bool {
        #[cfg(feature = "commit-observer")]
        {
            !EARLY_ADMISSION_BARRIER.get()
        }
        #[cfg(not(feature = "commit-observer"))]
        {
            true
        }
    }
}
/// Sealed write-set obligation: only run state/target, dispatch marker or raw
/// terminal usage changes; no reservation, history, quota or publication write.
pub(crate) struct OriginLifecycle {
    pub(super) _sealed: (),
}
#[cfg(feature = "commit-observer")]
thread_local! {
    static FULL_LIFECYCLE_INVALIDATION: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
#[cfg(feature = "commit-observer")]
/// Safe same-image test control: retain broad lifecycle invalidation.
pub fn use_full_lifecycle_invalidation(full: bool) {
    FULL_LIFECYCLE_INVALIDATION.set(full);
}
#[cfg(feature = "commit-observer")]
thread_local! {
    static EXCLUSIVE_PROVIDER_READS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
/// Safe same-image control retaining full-domain exclusive read custody.
#[cfg(feature = "commit-observer")]
pub fn use_exclusive_provider_reads(exclusive: bool) {
    EXCLUSIVE_PROVIDER_READS.set(exclusive);
}
pub(crate) fn shared_provider_reads() -> bool {
    #[cfg(feature = "commit-observer")]
    {
        !EXCLUSIVE_PROVIDER_READS.get()
    }
    #[cfg(not(feature = "commit-observer"))]
    {
        true
    }
}
impl OriginLifecycle {
    pub(crate) fn origin_only(&self) -> bool {
        #[cfg(feature = "commit-observer")]
        {
            !FULL_LIFECYCLE_INVALIDATION.get()
        }
        #[cfg(not(feature = "commit-observer"))]
        {
            true
        }
    }
}
#[cfg(feature = "commit-observer")]
thread_local! {
    static CONSERVATIVE_RANGE_INVALIDATION: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}
/// Same-image safe control: treat exact progress writes as semantic mutations.
#[cfg(feature = "commit-observer")]
pub fn use_conservative_range_invalidation(conservative: bool) {
    CONSERVATIVE_RANGE_INVALIDATION.set(conservative);
}
impl RangeProgress {
    pub(crate) fn invalidates(&self) -> bool {
        #[cfg(feature = "commit-observer")]
        return CONSERVATIVE_RANGE_INVALIDATION.get();
        #[cfg(not(feature = "commit-observer"))]
        false
    }
}
