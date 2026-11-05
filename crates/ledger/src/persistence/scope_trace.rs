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
    origin_write: bool,
    at: Instant,
}

pub(super) struct Granted<'a> {
    trace: &'a mut Trace,
    arrival: Arrival,
    order: u64,
    at: Instant,
}

/// Process-local observations of atomic domain admission.
pub struct ProviderScopeSample {
    pub phase: ProviderScopePhase,
    /// Actual granted lease mode, not inferred from the phase name.
    pub origin_write: bool,
    pub arrival: u64,
    pub grant: u64,
    pub wait: Duration,
    pub hold: Duration,
    /// Authority-intent lifetime; preserved progress does not close readers.
    pub authority_span: Duration,
}

impl Arrival {
    pub(super) fn capture(
        phase: ProviderScopePhase,
        order: u64,
        at: Instant,
        origin_write: bool,
    ) -> Self {
        Self {
            phase,
            order,
            at,
            origin_write,
        }
    }
    pub(super) fn granted(self, trace: &mut Trace, order: u64) -> Granted<'_> {
        Granted {
            trace,
            arrival: self,
            order,
            at: Instant::now(),
        }
    }
}

pub(super) struct Trace {
    family: String,
    samples: Vec<ProviderScopeSample>,
    flushed: usize,
}
impl Trace {
    pub(super) fn new(family: &str) -> Self {
        Self {
            family: family.to_owned(),
            samples: Vec::with_capacity(CAPACITY),
            flushed: 0,
        }
    }
    pub(super) fn flush(&mut self, final_chunk: bool) {
        use std::fmt::Write;
        let mut line = format!(
            "weaver-provider-scope {} {}:{}",
            self.family,
            self.flushed,
            u8::from(final_chunk)
        );
        for sample in &self.samples {
            let phase = match sample.phase {
                ProviderScopePhase::Other => "other",
                ProviderScopePhase::Admission => "admit",
                ProviderScopePhase::PrepareRange => "prepare",
                ProviderScopePhase::FinalQueue => "queue",
                ProviderScopePhase::RevalidateDelivery => "revalidate",
            };
            let _ = write!(
                line,
                " {phase}:{}:{}:{}:{}:{}:{}",
                sample.arrival,
                sample.grant,
                sample.wait.as_nanos(),
                sample.hold.as_nanos(),
                if sample.origin_write {
                    "origin"
                } else {
                    "exclusive"
                },
                sample.authority_span.as_nanos()
            );
        }
        eprintln!("{line}");
        self.flushed = self
            .flushed
            .checked_add(self.samples.len())
            .expect("diagnostic ordinal exhausted");
        self.samples.clear();
    }
    fn record(&mut self, sample: ProviderScopeSample) {
        if self.samples.len() == CAPACITY {
            self.flush(false);
        }
        self.samples.push(sample);
    }
}
impl Granted<'_> {
    pub(super) fn record(self, authority_span: Duration) {
        self.trace.record(ProviderScopeSample {
            phase: self.arrival.phase,
            authority_span,
            origin_write: self.arrival.origin_write,
            arrival: self.arrival.order,
            grant: self.order,
            wait: self.at.duration_since(self.arrival.at),
            hold: self.at.elapsed(),
        });
    }
}

#[cfg(test)]
#[path = "../../tests/unit/scope_trace.rs"]
mod tests;
