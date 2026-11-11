// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded, observed-server timing records. No admission decisions use them.
use super::ProviderScopePhase;
use std::{
    cell::Cell,
    sync::OnceLock,
    time::{Duration, Instant},
};
pub(super) const CAPACITY: usize = 64;

#[derive(Clone, Copy)]
pub(super) struct ReleaseTiming {
    pub requested: Instant,
    pub locked: Instant,
    pub removed: Instant,
    pub notified: Instant,
    pub returned: Instant,
}

pub(super) struct Completion {
    pub authority_span: Duration,
    pub releasing: Instant,
    pub transaction_nanos: u64,
    pub commit_total: u64,
    pub admission_nanos: [u64; 8],
    pub manifest_driver: [[u64; 8]; 2],
    pub release: Option<ReleaseTiming>,
}

#[derive(Clone, Copy)]
enum ReleaseCapture {
    Idle,
    Armed,
    Complete(ReleaseTiming),
}

thread_local! {
    static RELEASE: Cell<ReleaseCapture> = const { Cell::new(ReleaseCapture::Idle) };
}

pub(super) fn observe_release(release: impl FnOnce()) -> Option<ReleaseTiming> {
    struct Restore(ReleaseCapture);
    impl Drop for Restore {
        fn drop(&mut self) {
            RELEASE.set(self.0);
        }
    }
    let _restore = Restore(RELEASE.replace(ReleaseCapture::Armed));
    release();
    match RELEASE.get() {
        ReleaseCapture::Complete(timing) => Some(timing),
        _ => None,
    }
}

pub(super) fn capturing_release() -> bool {
    matches!(RELEASE.get(), ReleaseCapture::Armed)
}

pub(super) fn record_release(timing: ReleaseTiming) {
    RELEASE.set(ReleaseCapture::Complete(timing));
}

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
    begin_nanos: u64,
    begin_driver: [u64; 6],
    commit_before: u64,
    commit_io: Option<super::driver_observer::CommitIo>,
}

struct Timeline {
    arrived: Instant,
    granted: Instant,
    releasing: Instant,
    begin_nanos: u64,
    transaction_nanos: u64,
    commit_nanos: u64,
    admission_nanos: [u64; 8],
    manifest_driver: [[u64; 8]; 2],
    begin_driver: [u64; 6],
    release: Option<ReleaseTiming>,
    commit_io: Option<super::driver_observer::CommitIo>,
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
            begin_nanos: 0,
            begin_driver: [0; 6],
            commit_before: 0,
            commit_io: None,
        }
    }
}

pub(super) struct Trace {
    family: String,
    samples: Vec<ProviderScopeSample>,
    flushed: usize,
    request: Option<String>,
    timeline: Vec<Timeline>,
}
impl Trace {
    pub(super) fn new(family: &str) -> Self {
        Self {
            family: family.to_owned(),
            samples: Vec::with_capacity(CAPACITY),
            flushed: 0,
            request: None,
            timeline: Vec::new(),
        }
    }
    pub(super) fn with_request(mut self, request: &str) -> Self {
        self.request = Some(request.to_owned());
        self.timeline = Vec::with_capacity(CAPACITY);
        self
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
        if let Some(request) = &self.request {
            static CLOCK: OnceLock<Instant> = OnceLock::new();
            let clock = *CLOCK.get_or_init(Instant::now);
            let before_epoch = |at: Instant| {
                at.checked_duration_since(clock).map_or_else(
                    || -(clock.duration_since(at).as_nanos() as i128),
                    |elapsed| elapsed.as_nanos() as i128,
                )
            };
            let mut line = format!("weaver-provider-scope-timeline {} {}", self.family, request);
            for (sample, time) in self.samples.iter().zip(self.timeline.drain(..)) {
                let _ = write!(
                    line,
                    " {}:{}:{}:{}:{}:{}:{}",
                    sample.arrival,
                    before_epoch(time.arrived),
                    before_epoch(time.granted),
                    before_epoch(time.releasing),
                    time.begin_nanos,
                    time.transaction_nanos,
                    time.commit_nanos,
                );
                for nanos in time.admission_nanos {
                    let _ = write!(line, ":{nanos}");
                }
                // Poll wall/CPU, prepare wall/CPU, pending count, poll count.
                for count in time
                    .begin_driver
                    .into_iter()
                    .chain(time.manifest_driver.into_iter().flatten())
                {
                    let _ = write!(line, ":{count}");
                }
                super::driver_observer::CommitIo::append(time.commit_io, &mut line);
                // Versioned extension. The earlier releasing timestamp is a
                // request to drop the lease, before acquiring the scheduler lock.
                if let Some(release) = time.release {
                    let _ = write!(
                        line,
                        ":1:{}:{}:{}:{}:{}",
                        before_epoch(release.requested),
                        before_epoch(release.locked),
                        before_epoch(release.removed),
                        before_epoch(release.notified),
                        before_epoch(release.returned),
                    );
                } else {
                    let _ = write!(line, ":0:0:0:0:0:0");
                }
            }
            eprintln!("{line}");
        }
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
    pub(super) fn committed_io(&mut self, io: Option<super::driver_observer::CommitIo>) {
        self.commit_io = io;
    }

    pub(super) fn has_timeline(&self) -> bool {
        self.trace.request.is_some()
    }

    pub(super) fn opened(&mut self, begin_nanos: u64, commit_before: u64, begin_driver: [u64; 6]) {
        self.begin_nanos = begin_nanos;
        self.commit_before = commit_before;
        self.begin_driver = begin_driver;
    }

    pub(super) fn record(self, completion: Completion) {
        let Completion {
            authority_span,
            releasing,
            transaction_nanos,
            commit_total,
            admission_nanos,
            manifest_driver,
            release,
        } = completion;
        self.trace.record(ProviderScopeSample {
            phase: self.arrival.phase,
            authority_span,
            origin_write: self.arrival.origin_write,
            arrival: self.arrival.order,
            grant: self.order,
            wait: self.at.duration_since(self.arrival.at),
            hold: self.at.elapsed(),
        });
        if self.trace.request.is_some() {
            self.trace.timeline.push(Timeline {
                arrived: self.arrival.at,
                granted: self.at,
                releasing,
                begin_nanos: self.begin_nanos,
                transaction_nanos,
                commit_nanos: commit_total.saturating_sub(self.commit_before),
                admission_nanos,
                manifest_driver,
                begin_driver: self.begin_driver,
                release,
                commit_io: self.commit_io,
            });
        }
    }
}

#[cfg(test)]
#[path = "../../tests/unit/scope_trace.rs"]
mod tests;
