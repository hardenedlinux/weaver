// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Fixed-cardinality, session-local performance observations, never authority.
use std::time::{Duration, Instant};

/// Saturating statistical attempts and elapsed nanoseconds, including failures.
/// These values never certify an effect or authorize release of a hold.
#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub struct Timing {
    pub attempts: u64,
    pub nanos: u64,
}
impl Timing {
    pub(super) fn record(&mut self, elapsed: Duration) {
        self.attempts = self.attempts.saturating_add(1);
        self.nanos = self
            .nanos
            .saturating_add(u64::try_from(elapsed.as_nanos()).unwrap_or(u64::MAX));
    }
}
/// Intervals overlap: never sum them into a critical-path latency or a receipt.
/// Reset on session replacement; failed attempts are included, not just successes.
#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub struct TransactionTimings {
    pub owner_gate_wait: Timing,
    pub domain_keys: Timing,
    pub domain_wait: Timing,
    pub transaction_begin: Timing,
    pub owner_gate_hold: Timing,
    pub domain_hold: Timing,
    pub transaction_hold: Timing,
    pub commit: Timing,
    pub rollback: Timing,
    pub provider_oauth_prepare: Timing,
    pub provider_oauth_check: Timing,
    pub provider_domain: Timing,
    pub provider_pending: Timing,
    pub provider_review: Timing,
    pub provider_birth: Timing,
    pub provider_publication_prepare: Timing,
    pub provider_profile: Timing,
    pub provider_claim: Timing,
    pub provider_cedar: Timing,
    pub provider_request: Timing,
    pub provider_queue: Timing,
}
pub(super) fn measure<T>(sample: &mut Timing, run: impl FnOnce() -> T) -> T {
    struct Guard<'a> {
        sample: &'a mut Timing,
        start: Instant,
    }
    impl Drop for Guard<'_> {
        fn drop(&mut self) {
            self.sample.record(self.start.elapsed());
        }
    }
    let guard = Guard {
        sample,
        start: Instant::now(),
    };
    let result = run();
    drop(guard);
    result
}

impl TransactionTimings {
    /// Subtract observations from this same live session. Not a recovery check.
    pub fn since(self, earlier: Self) -> Self {
        fn delta(now: Timing, old: Timing) -> Timing {
            Timing {
                attempts: now.attempts.saturating_sub(old.attempts),
                nanos: now.nanos.saturating_sub(old.nanos),
            }
        }
        Self {
            owner_gate_wait: delta(self.owner_gate_wait, earlier.owner_gate_wait),
            domain_keys: delta(self.domain_keys, earlier.domain_keys),
            domain_wait: delta(self.domain_wait, earlier.domain_wait),
            transaction_begin: delta(self.transaction_begin, earlier.transaction_begin),
            owner_gate_hold: delta(self.owner_gate_hold, earlier.owner_gate_hold),
            domain_hold: delta(self.domain_hold, earlier.domain_hold),
            transaction_hold: delta(self.transaction_hold, earlier.transaction_hold),
            commit: delta(self.commit, earlier.commit),
            rollback: delta(self.rollback, earlier.rollback),
            provider_oauth_prepare: delta(
                self.provider_oauth_prepare,
                earlier.provider_oauth_prepare,
            ),
            provider_oauth_check: delta(self.provider_oauth_check, earlier.provider_oauth_check),
            provider_domain: delta(self.provider_domain, earlier.provider_domain),
            provider_pending: delta(self.provider_pending, earlier.provider_pending),
            provider_review: delta(self.provider_review, earlier.provider_review),
            provider_birth: delta(self.provider_birth, earlier.provider_birth),
            provider_publication_prepare: delta(
                self.provider_publication_prepare,
                earlier.provider_publication_prepare,
            ),
            provider_profile: delta(self.provider_profile, earlier.provider_profile),
            provider_claim: delta(self.provider_claim, earlier.provider_claim),
            provider_cedar: delta(self.provider_cedar, earlier.provider_cedar),
            provider_request: delta(self.provider_request, earlier.provider_request),
            provider_queue: delta(self.provider_queue, earlier.provider_queue),
        }
    }
}
