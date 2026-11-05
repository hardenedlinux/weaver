// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{CAPACITY, ProviderScopePhase, ProviderScopeSample, Trace};
use proptest::{prop_assert, prop_assert_eq, proptest};
use std::time::Duration;

proptest! {
    #[test]
    fn bounded_trace_retains_every_requalification(count in 1usize..256) {
        let mut trace = Trace::new("trace-test");
        for ordinal in 0..count {
            trace.record(ProviderScopeSample {phase: ProviderScopePhase::RevalidateDelivery,
                arrival: ordinal as u64*2+1, grant: ordinal as u64*2+2,
                wait: Duration::ZERO, hold: Duration::ZERO});
            prop_assert!(trace.samples.len() <= CAPACITY);
            prop_assert_eq!(trace.flushed + trace.samples.len(), ordinal+1);
        }
        trace.flush(true);
        prop_assert_eq!(trace.flushed, count);
        prop_assert!(trace.samples.is_empty());
        prop_assert_eq!(trace.samples.capacity(), CAPACITY);
    }
}
