//! Transport projection only. Statistics never become source or execution facts.
use crate::pb;
use weaver_telemetry::{Metrics, Signal};

pub(crate) fn snapshot(metrics: &Metrics) -> pb::TelemetrySnapshot {
    let s = metrics.snapshot();
    pb::TelemetrySnapshot {
        compilations_succeeded: s.count(Signal::CompilationSucceeded),
        compilations_failed: s.count(Signal::CompilationFailed),
        provider_admitted: s.count(Signal::ProviderAdmitted),
        provider_completed: s.count(Signal::ProviderCompleted),
        provider_failed: s.count(Signal::ProviderFailed),
        response_frames_queued: s.count(Signal::ResponseFramesQueued),
        queue_wait_failed: s.count(Signal::QueueWaitFailed),
        rpc_auth_rejected: s.count(Signal::RpcAuthRejected),
        snapshot_reads: s.count(Signal::SnapshotReads),
    }
}
