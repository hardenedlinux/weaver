// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Metrics, SIGNALS, Signal};
use proptest::{prop_assert_eq, proptest};
use std::sync::atomic::Ordering;

proptest! {
    #[test]
    fn observations_are_monotone_and_restart_local(events in proptest::collection::vec(0usize..SIGNALS, 0..512)) {
        let metrics = Metrics::default();
        let mut expected = [0; SIGNALS];
        for index in events {
            // This array is the complete public event vocabulary.
            let signal = [Signal::CompilationSucceeded, Signal::CompilationFailed,
                Signal::ProviderAdmitted, Signal::ProviderCompleted, Signal::ProviderFailed,
                Signal::ResponseFramesQueued, Signal::QueueWaitFailed,
                Signal::RpcAuthRejected, Signal::SnapshotReads][index];
            metrics.record(signal);
            expected[index] += 1;
            prop_assert_eq!(metrics.snapshot().counters, expected);
        }
        prop_assert_eq!(Metrics::default().snapshot().counters, [0; SIGNALS]);
    }
}

#[test]
fn concurrent_recording_does_not_lose_events() {
    let metrics = Metrics::default();
    std::thread::scope(|scope| {
        for _ in 0..12 {
            scope.spawn(|| {
                for _ in 0..1000 {
                    metrics.record(Signal::ProviderAdmitted);
                }
            });
        }
    });
    assert_eq!(metrics.snapshot().count(Signal::ProviderAdmitted), 12_000);
}

#[test]
fn full_counters_saturate_without_affecting_other_observations() {
    let metrics = Metrics::default();
    metrics.counters[0].store(u64::MAX, Ordering::Relaxed);
    metrics.record(Signal::CompilationSucceeded);
    metrics.record(Signal::CompilationFailed);
    assert_eq!(
        metrics.snapshot().count(Signal::CompilationSucceeded),
        u64::MAX
    );
    assert_eq!(metrics.snapshot().count(Signal::CompilationFailed), 1);
}
