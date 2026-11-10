// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Arrival, CAPACITY, Completion, ProviderScopePhase, ProviderScopeSample, Trace};
use proptest::{prop_assert, prop_assert_eq, proptest};
use std::time::{Duration, Instant};

#[test]
fn begin_driver_counters_follow_their_admission_grant() {
    let mut trace = Trace::new("trace-test").with_request("request");
    for (ordinal, counters) in [(1, [17, 13, 7, 5, 1, 2]), (3, [31, 29, 0, 0, 0, 1])] {
        let mut grant = Arrival::capture(
            ProviderScopePhase::Admission,
            ordinal,
            Instant::now(),
            false,
        )
        .granted(&mut trace, ordinal + 1);
        grant.opened(41, 23, counters);
        grant.record(Completion {
            authority_span: Duration::ZERO,
            releasing: Instant::now(),
            transaction_nanos: 53,
            commit_total: 37,
            admission_nanos: [0; 8],
            manifest_driver: [[ordinal; 8], [ordinal + 1; 8]],
            release: None,
        });
    }
    assert_eq!(trace.samples[0].arrival, 1);
    assert_eq!(trace.samples[1].arrival, 3);
    assert_eq!(trace.timeline[0].begin_driver, [17, 13, 7, 5, 1, 2]);
    assert_eq!(trace.timeline[1].begin_driver, [31, 29, 0, 0, 0, 1]);
    assert_eq!(trace.timeline[1].manifest_driver, [[3; 8], [4; 8]]);
}

proptest! {
    #[test]
    fn bounded_trace_retains_every_requalification(count in 1usize..256) {
        let mut trace = Trace::new("trace-test");
        for ordinal in 0..count {
            trace.record(ProviderScopeSample {origin_write: ordinal % 2 == 0, phase: ProviderScopePhase::RevalidateDelivery,
                arrival: ordinal as u64*2+1, grant: ordinal as u64*2+2,
                wait: Duration::ZERO, authority_span: Duration::ZERO, hold: Duration::ZERO});
            prop_assert!(trace.samples.len() <= CAPACITY);
            prop_assert_eq!(trace.flushed + trace.samples.len(), ordinal+1);
        }
        trace.flush(true);
        prop_assert_eq!(trace.flushed, count);
        prop_assert!(trace.samples.is_empty());
        prop_assert_eq!(trace.samples.capacity(), CAPACITY);
    }
}
