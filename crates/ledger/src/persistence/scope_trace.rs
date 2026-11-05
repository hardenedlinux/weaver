// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded, observed-server timing records. No admission decisions use them.
use super::ProviderScopePhase;
use std::time::{Duration, Instant};
pub(super) const CAPACITY: usize = 64;

pub(super) struct Arrival {
    phase: ProviderScopePhase,
    order: u64,
    at: Instant,
}

pub(super) struct Granted<'a> {
    trace: &'a mut Vec<ProviderScopeSample>,
    arrival: Arrival,
    order: u64,
    at: Instant,
}

/// Process-local observations of atomic domain admission.
pub struct ProviderScopeSample {
    pub phase: ProviderScopePhase,
    pub arrival: u64,
    pub grant: u64,
    pub wait: Duration,
    pub hold: Duration,
}

impl Arrival {
    pub(super) fn capture(phase: ProviderScopePhase, order: u64, at: Instant) -> Self {
        Self { phase, order, at }
    }
    pub(super) fn granted(self, trace: &mut Vec<ProviderScopeSample>, order: u64) -> Granted<'_> {
        Granted {
            trace,
            arrival: self,
            order,
            at: Instant::now(),
        }
    }
}

impl Granted<'_> {
    pub(super) fn record(self) {
        if self.trace.len() < CAPACITY {
            self.trace.push(ProviderScopeSample {
                phase: self.arrival.phase,
                arrival: self.arrival.order,
                grant: self.order,
                wait: self.at.duration_since(self.arrival.at),
                hold: self.at.elapsed(),
            });
        }
    }
}
