//! Fixed-cardinality local operational observations. No payloads, callbacks,
//! export transport, durable evidence or execution capabilities enter this API.
use std::sync::atomic::{AtomicU64, Ordering};

/// Event names are closed; caller-controlled identifiers cannot become labels.
#[derive(Clone, Copy, Debug)]
#[repr(usize)]
pub enum Signal {
    CompilationSucceeded,
    CompilationFailed,
    ProviderAdmitted,
    ProviderCompleted,
    ProviderFailed,
    ResponseFramesQueued,
    QueueWaitFailed,
    RpcAuthRejected,
    SnapshotReads,
}
const SIGNALS: usize = 9;

/// Process-local counters, always available without an exporter or a worker.
/// Readers obtain independent atomic observations, not a coherent ledger cut.
#[derive(Default)]
pub struct Metrics {
    counters: [AtomicU64; SIGNALS],
}

/// A detached statistical observation. Restart resets it; it cannot prove that
/// an operation executed, did not execute, committed, or settled its budget.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Snapshot {
    counters: [u64; SIGNALS],
}
impl Metrics {
    /// Constant storage and no allocation, IO, locks or foreign callbacks.
    /// Saturation preserves monotonic observations without counter wraparound.
    pub fn record(&self, signal: Signal) {
        let _ = self.counters[signal as usize].fetch_update(
            Ordering::Relaxed,
            Ordering::Relaxed,
            |n| Some(n.saturating_add(1)),
        );
    }
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            counters: std::array::from_fn(|i| self.counters[i].load(Ordering::Relaxed)),
        }
    }
}
impl Snapshot {
    pub fn count(&self, signal: Signal) -> u64 {
        self.counters[signal as usize]
    }
}

#[cfg(test)]
#[path = "../tests/unit/metrics.rs"]
mod tests;
