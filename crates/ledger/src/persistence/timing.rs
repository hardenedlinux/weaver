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
    #[cfg(feature = "commit-observer")]
    pub(super) fn merge(&mut self, sample: Self) {
        self.attempts = self.attempts.saturating_add(sample.attempts);
        self.nanos = self.nanos.saturating_add(sample.nanos);
    }
}
/// Intervals overlap: never sum them into a critical-path latency or a receipt.
/// Reset on session replacement; failed attempts are included, not just successes.
#[derive(Clone, Copy, Debug, Default, serde::Serialize)]
pub struct TransactionTimings {
    pub owner_gate_wait: Timing,
    pub domain_keys: Timing,
    pub domain_wait: Timing,
    pub authority_span: Timing,
    pub transaction_begin: Timing,
    #[cfg(feature = "commit-observer")]
    pub transaction_begin_poll: Timing,
    #[cfg(feature = "commit-observer")]
    pub transaction_begin_cpu: Timing,
    #[cfg(feature = "commit-observer")]
    pub transaction_begin_prepare: Timing,
    #[cfg(feature = "commit-observer")]
    pub transaction_begin_prepare_cpu: Timing,
    #[cfg(feature = "commit-observer")]
    pub transaction_begin_pending: u64,
    pub owner_gate_hold: Timing,
    pub domain_hold: Timing,
    pub transaction_hold: Timing,
    pub commit: Timing,
    #[cfg(feature = "commit-observer")]
    pub commit_poll: Timing,
    #[cfg(feature = "commit-observer")]
    pub commit_cpu: Timing,
    #[cfg(feature = "commit-observer")]
    pub commit_sync: Timing,
    #[cfg(feature = "commit-observer")]
    pub commit_pending: u64,
    pub rollback: Timing,
    pub provider_oauth_prepare: Timing,
    pub provider_oauth_check: Timing,
    pub provider_domain: Timing,
    pub provider_domain_prepare: Timing,
    pub provider_pending: Timing,
    pub provider_review: Timing,
    pub provider_birth: Timing,
    pub provider_publication_prepare: Timing,
    pub provider_profile: Timing,
    pub provider_claim: Timing,
    pub provider_history: Timing,
    pub provider_manifest: Timing,
    pub provider_original: Timing,
    pub provider_original_prepare: Timing,
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

/// Host monotonic timestamp shared by the Rust and Go test processes.
#[cfg(feature = "commit-observer")]
pub fn provider_observation_nanos() -> u128 {
    let stamp = rustix::time::clock_gettime(rustix::time::ClockId::Monotonic);
    stamp.tv_sec as u128 * 1_000_000_000 + stamp.tv_nsec as u128
}

#[cfg(feature = "commit-observer")]
pub(super) fn thread_cpu_time() -> Option<Duration> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    {
        use rustix::time::{ClockId, clock_gettime};
        clock_gettime(ClockId::ThreadCPUTime).try_into().ok()
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    None
}

#[cfg(feature = "commit-observer")]
pub(super) fn observe_polls<F: std::future::Future>(
    future: F,
    wall: &mut Timing,
    cpu: &mut Timing,
    pending: &mut u64,
) -> F::Output {
    let mut future = std::pin::pin!(future);
    futures_executor::block_on(std::future::poll_fn(|cx| {
        let result = measure(wall, || {
            let start = thread_cpu_time();
            let result = future.as_mut().poll(cx);
            if let (Some(start), Some(end)) = (start, thread_cpu_time())
                && let Some(elapsed) = end.checked_sub(start)
            {
                cpu.record(elapsed);
            }
            result
        });
        if result.is_pending() {
            *pending = pending.saturating_add(1);
        }
        result
    }))
}

impl TransactionTimings {
    #[cfg(feature = "commit-observer")]
    pub(super) fn begin_driver_counters(&self) -> [u64; 6] {
        [
            self.transaction_begin_poll.nanos,
            self.transaction_begin_cpu.nanos,
            self.transaction_begin_prepare.nanos,
            self.transaction_begin_prepare_cpu.nanos,
            self.transaction_begin_pending,
            self.transaction_begin_poll.attempts,
        ]
    }

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
            authority_span: delta(self.authority_span, earlier.authority_span),
            transaction_begin: delta(self.transaction_begin, earlier.transaction_begin),
            #[cfg(feature = "commit-observer")]
            transaction_begin_poll: delta(
                self.transaction_begin_poll,
                earlier.transaction_begin_poll,
            ),
            #[cfg(feature = "commit-observer")]
            transaction_begin_cpu: delta(self.transaction_begin_cpu, earlier.transaction_begin_cpu),
            #[cfg(feature = "commit-observer")]
            transaction_begin_prepare: delta(
                self.transaction_begin_prepare,
                earlier.transaction_begin_prepare,
            ),
            #[cfg(feature = "commit-observer")]
            transaction_begin_prepare_cpu: delta(
                self.transaction_begin_prepare_cpu,
                earlier.transaction_begin_prepare_cpu,
            ),
            #[cfg(feature = "commit-observer")]
            transaction_begin_pending: self
                .transaction_begin_pending
                .saturating_sub(earlier.transaction_begin_pending),
            owner_gate_hold: delta(self.owner_gate_hold, earlier.owner_gate_hold),
            domain_hold: delta(self.domain_hold, earlier.domain_hold),
            transaction_hold: delta(self.transaction_hold, earlier.transaction_hold),
            commit: delta(self.commit, earlier.commit),
            #[cfg(feature = "commit-observer")]
            commit_poll: delta(self.commit_poll, earlier.commit_poll),
            #[cfg(feature = "commit-observer")]
            commit_cpu: delta(self.commit_cpu, earlier.commit_cpu),
            #[cfg(feature = "commit-observer")]
            commit_sync: delta(self.commit_sync, earlier.commit_sync),
            #[cfg(feature = "commit-observer")]
            commit_pending: self.commit_pending.saturating_sub(earlier.commit_pending),
            rollback: delta(self.rollback, earlier.rollback),
            provider_oauth_prepare: delta(
                self.provider_oauth_prepare,
                earlier.provider_oauth_prepare,
            ),
            provider_oauth_check: delta(self.provider_oauth_check, earlier.provider_oauth_check),
            provider_domain: delta(self.provider_domain, earlier.provider_domain),
            provider_domain_prepare: delta(
                self.provider_domain_prepare,
                earlier.provider_domain_prepare,
            ),
            provider_pending: delta(self.provider_pending, earlier.provider_pending),
            provider_review: delta(self.provider_review, earlier.provider_review),
            provider_birth: delta(self.provider_birth, earlier.provider_birth),
            provider_publication_prepare: delta(
                self.provider_publication_prepare,
                earlier.provider_publication_prepare,
            ),
            provider_profile: delta(self.provider_profile, earlier.provider_profile),
            provider_claim: delta(self.provider_claim, earlier.provider_claim),
            provider_history: delta(self.provider_history, earlier.provider_history),
            provider_manifest: delta(self.provider_manifest, earlier.provider_manifest),
            provider_original: delta(self.provider_original, earlier.provider_original),
            provider_original_prepare: delta(
                self.provider_original_prepare,
                earlier.provider_original_prepare,
            ),
            provider_cedar: delta(self.provider_cedar, earlier.provider_cedar),
            provider_request: delta(self.provider_request, earlier.provider_request),
            provider_queue: delta(self.provider_queue, earlier.provider_queue),
        }
    }
}
