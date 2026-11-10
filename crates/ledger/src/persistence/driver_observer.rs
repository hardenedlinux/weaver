// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Observe Turso driver spans during BEGIN and COMMIT.
use super::timing::{Timing, thread_cpu_time};
use std::{
    cell::RefCell,
    sync::OnceLock,
    time::{Duration, Instant},
};
use tracing::{Dispatch, Metadata, Subscriber, span::Id, subscriber::NoSubscriber};
use tracing_subscriber::{
    Layer,
    filter::dynamic_filter_fn,
    layer::{Context, SubscriberExt},
    registry::LookupSpan,
};

const UNIX_IO_NAMES: [&str; 6] = ["pread", "pwrite", "pwritev", "sync", "size", "truncate"];

#[derive(Default)]
struct SpanTiming {
    depth: usize,
    start: Option<(Instant, Option<Duration>)>,
    wall: Timing,
    cpu: Timing,
}

impl SpanTiming {
    fn enter(&mut self) {
        if self.depth == 0 {
            self.start = Some((Instant::now(), thread_cpu_time()));
        }
        self.depth += 1;
    }

    fn exit(&mut self) {
        self.depth -= 1;
        if self.depth == 0
            && let Some((wall, cpu)) = self.start.take()
        {
            if let (Some(cpu), Some(end)) = (cpu, thread_cpu_time())
                && let Some(elapsed) = end.checked_sub(cpu)
            {
                self.cpu.record(elapsed);
            }
            self.wall.record(wall.elapsed());
        }
    }

    fn counters(&self) -> [u64; 3] {
        [self.wall.nanos, self.cpu.nanos, self.wall.attempts]
    }
}

/// Union of Unix I/O spans, followed by each fixed I/O kind. Kind intervals may overlap.
#[derive(Clone, Copy, Default)]
pub(super) struct CommitIo {
    rows: [[u64; 3]; 7],
}

impl CommitIo {
    pub(super) fn append(observation: Option<Self>, line: &mut String) {
        use std::fmt::Write;
        let _ = write!(line, ":{}", u8::from(observation.is_some()));
        for row in observation.unwrap_or_default().rows {
            let [wall, cpu, calls] = row;
            let _ = write!(line, ":{wall}:{cpu}:{calls}");
        }
    }
}

#[derive(Default)]
struct Observation {
    span: Option<DriverSpan>,
    selected: SpanTiming,
    capture_io: bool,
    io_total: SpanTiming,
    io: [SpanTiming; 6],
}

impl Observation {
    fn enter(&mut self, observed: Option<DriverSpan>, io: Option<usize>) {
        if observed.is_some() && observed == self.span {
            self.selected.enter();
        }
        if self.capture_io
            && let Some(kind) = io
        {
            self.io_total.enter();
            self.io[kind].enter();
        }
    }

    fn exit(&mut self, observed: Option<DriverSpan>, io: Option<usize>) {
        if self.capture_io
            && let Some(kind) = io
        {
            self.io[kind].exit();
            self.io_total.exit();
        }
        if observed.is_some() && observed == self.span {
            self.selected.exit();
        }
    }

    fn commit_io(&self) -> CommitIo {
        CommitIo {
            rows: std::array::from_fn(|index| {
                if index == 0 {
                    self.io_total.counters()
                } else {
                    self.io[index - 1].counters()
                }
            }),
        }
    }
}

fn unix_io_kind(meta: &Metadata<'_>) -> Option<usize> {
    (meta.target() == "turso_core::io::unix")
        .then(|| UNIX_IO_NAMES.iter().position(|name| *name == meta.name()))
        .flatten()
}

thread_local! {
    static SAMPLE: RefCell<Observation> = RefCell::default();
}

struct DriverLayer;

impl<S: Subscriber + for<'span> LookupSpan<'span>> Layer<S> for DriverLayer {
    fn on_enter(&self, id: &Id, context: Context<'_, S>) {
        if let Some(span) = context.span(id) {
            let meta = span.metadata();
            SAMPLE.with_borrow_mut(|sample| {
                sample.enter(DriverSpan::identify(meta), unix_io_kind(meta))
            });
        }
    }

    fn on_exit(&self, id: &Id, context: Context<'_, S>) {
        if let Some(span) = context.span(id) {
            let meta = span.metadata();
            SAMPLE.with_borrow_mut(|sample| {
                sample.exit(DriverSpan::identify(meta), unix_io_kind(meta))
            });
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum DriverSpan {
    Prepare,
    UnixSync,
}

impl DriverSpan {
    fn identify(meta: &Metadata<'_>) -> Option<Self> {
        match (meta.target(), meta.name()) {
            ("turso_core::connection", "_prepare") => Some(Self::Prepare),
            ("turso_core::io::unix", "sync") => Some(Self::UnixSync),
            _ => None,
        }
    }
}

fn driver_dispatch() -> &'static Dispatch {
    static DRIVER: OnceLock<(Dispatch, Dispatch)> = OnceLock::new();
    let (_, observer) = DRIVER.get_or_init(|| {
        // With one registered dispatcher, tracing caches a new callsite's
        // interest from the registering thread's current default. Keep a
        // silent dispatcher registered so interest accounts for both observed
        // and unobserved calls regardless of which thread reaches Turso first.
        let silent = Dispatch::new(NoSubscriber::new());
        let layer = DriverLayer.with_filter(dynamic_filter_fn(|meta, _| {
            meta.is_span()
                && (DriverSpan::identify(meta).is_some()
                    || (unix_io_kind(meta).is_some()
                        && SAMPLE.with_borrow(|sample| sample.capture_io)))
        }));
        let observer = Dispatch::new(tracing_subscriber::registry().with(layer));
        (silent, observer)
    });
    observer
}

fn observe_sample<T>(
    span: DriverSpan,
    capture_io: bool,
    run: impl FnOnce() -> T,
) -> (T, Observation) {
    let dispatch = driver_dispatch();
    SAMPLE.with_borrow_mut(|sample| {
        *sample = Observation {
            span: Some(span),
            capture_io,
            ..Observation::default()
        }
    });
    let result = tracing::dispatcher::with_default(dispatch, run);
    (result, SAMPLE.take())
}

pub(super) fn observe<T>(span: DriverSpan, run: impl FnOnce() -> T) -> (T, Timing, Timing) {
    let (result, observation) = observe_sample(span, false, run);
    (result, observation.selected.wall, observation.selected.cpu)
}

pub(super) fn observe_commit<T>(
    capture_io: bool,
    run: impl FnOnce() -> T,
) -> (T, Timing, Option<CommitIo>) {
    let (result, observation) = observe_sample(DriverSpan::UnixSync, capture_io, run);
    let io = capture_io.then(|| observation.commit_io());
    (result, observation.selected.wall, io)
}

#[cfg(test)]
#[path = "../../tests/unit/driver_observer.rs"]
mod tests;

/// Wall, poll wall/CPU, prepare wall/CPU, pending, polls, and reads.
pub(super) fn observe_read<F: std::future::Future>(future: F) -> (F::Output, [u64; 8]) {
    let start = Instant::now();
    let (mut poll, mut cpu, mut pending) = (Timing::default(), Timing::default(), 0);
    let (result, prepare, prepare_cpu) = observe(DriverSpan::Prepare, || {
        super::timing::observe_polls(future, &mut poll, &mut cpu, &mut pending)
    });
    let wall = u64::try_from(start.elapsed().as_nanos()).unwrap_or(u64::MAX);
    (
        result,
        [
            wall,
            poll.nanos,
            cpu.nanos,
            prepare.nanos,
            prepare_cpu.nanos,
            pending,
            poll.attempts,
            1,
        ],
    )
}
