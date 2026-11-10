// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One blocking loop; the embedding runtime owns thread tracking and VM cleanup.
use super::{Command, Phase, Reply, Shared, SourceJobError, Work};
use crate::{OwnedSource, SourceError};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
/// Move this receiver to the existing tracked blocking owner before constructing
/// its VM. The compiler can borrow that thread-affine, non-Send runtime.
pub struct SourceInbox {
    pub(super) receiver: mpsc::Receiver<Command>,
    pub(super) shared: Arc<Shared>,
}
impl SourceInbox {
    /// Run synchronous approved compilation. No lock is held during foreign
    /// calls or content comparison. Finish/VM cleanup must precede owner join ack.
    /// This does not sandbox arbitrary callbacks or implement source authenticity.
    pub fn run(self, compile: impl FnMut(&OwnedSource) -> Result<OwnedSource, SourceError>) {
        self.run_with_governor(
            compile,
            |owner, original| owner(original),
            |_, _| Err(SourceError::Contract),
        );
    }
    /// Run compilation and Governor derivation on the same affine owner.
    pub fn run_with_governor<C>(
        self,
        owner: C,
        mut compile: impl FnMut(&mut C, &OwnedSource) -> Result<OwnedSource, SourceError>,
        mut derive: impl FnMut(&mut C, &crate::GovernorCut) -> Result<Vec<String>, SourceError>,
    ) {
        self.run_with_cancellable_governor(
            owner,
            |owner, original, _| compile(owner, original),
            |owner, input| match input {
                crate::Derivation::Governor(cut) => {
                    derive(owner, cut).map(crate::DerivationOutput::Nodes)
                }
                crate::Derivation::FactImpact { .. } => Err(SourceError::Contract),
            },
        );
    }
    /// Pass the request cancellation token into a cooperative compiler.
    pub fn run_with_cancellable_governor<C>(
        mut self,
        mut owner: C,
        mut compile: impl FnMut(
            &mut C,
            &OwnedSource,
            &CancellationToken,
        ) -> Result<OwnedSource, SourceError>,
        mut derive: impl FnMut(
            &mut C,
            &crate::Derivation,
        ) -> Result<crate::DerivationOutput, SourceError>,
    ) {
        while let Some(command) = self.receiver.blocking_recv() {
            if *self.shared.gate() {
                break;
            }
            match command {
                Command::Stop => break,
                Command::Compile(work) => self.execute(*work, &mut |original, cancel| {
                    if governor_timing() {
                        trace_compile("begin");
                    }
                    let result = compile(&mut owner, original, cancel);
                    if governor_timing() {
                        trace_compile("end");
                    }
                    result
                }),
                Command::Derive {
                    input,
                    reply,
                    _slot,
                    queued,
                } => self.execute_derivation(&input, reply, queued, || derive(&mut owner, &input)),
            }
            if *self.shared.gate() {
                break;
            }
        }
        if governor_timing() {
            let wall = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default();
            eprintln!(
                "weaver shutdown stage=scheme-owner-drop-begin wall_ns={}",
                wall.as_nanos()
            );
        }
        drop(owner);
    }
    fn execute_derivation(
        &self,
        input: &crate::Derivation,
        reply: tokio::sync::oneshot::Sender<super::state::DerivationReply>,
        queued: Option<std::time::Instant>,
        derive: impl FnOnce() -> Result<crate::DerivationOutput, SourceError>,
    ) {
        if reply.is_closed() {
            return;
        }
        let started = queued.map(|queued| (queued, std::time::Instant::now()));
        let result = derive();
        let finished = started.map(|_| std::time::Instant::now());
        if matches!(result, Err(SourceError::Scheme)) {
            self.shared.stop();
        }
        if let (Some((queued, started)), Some(finished)) = (started, finished) {
            let derive_ns = finished.duration_since(started).as_nanos();
            let cut_sha256 = match input {
                crate::Derivation::Governor(cut) => trace_digest(cut),
                crate::Derivation::FactImpact { .. } => trace_digest(input),
            };
            let ready_sha256 = match (input, result.as_ref().ok()) {
                (_, Some(crate::DerivationOutput::Nodes(nodes))) => Some(trace_digest(nodes)),
                (
                    crate::Derivation::Governor(cut),
                    Some(crate::DerivationOutput::Indices(indices)),
                ) => indices
                    .iter()
                    .map(|&index| cut.topology.nodes.get(index))
                    .collect::<Option<Vec<_>>>()
                    .map(|nodes| trace_digest(&nodes)),
                _ => None,
            };
            eprintln!(
                "weaver-governor-owner wait_ns={} derive_ns={derive_ns} ok={} cut_sha256={cut_sha256} ready_sha256={}",
                started.duration_since(queued).as_nanos(),
                result.is_ok(),
                ready_sha256.as_deref().unwrap_or("unavailable"),
            );
        }
        let timing = started.zip(finished).map(|((queued, started), finished)| {
            [queued, started, finished, std::time::Instant::now()]
        });
        let _ = reply.send(super::state::DerivationReply { result, timing });
    }
    fn execute(
        &self,
        work: Work,
        compile: &mut impl FnMut(&OwnedSource, &CancellationToken) -> Result<OwnedSource, SourceError>,
    ) {
        {
            let closed = self.shared.gate();
            let mut phase = work.state.guard();
            if *closed || *phase == Phase::Cancelled {
                return;
            }
            *phase = Phase::Running;
        }
        let result = compile(&work.original, &work.cancel)
            .and_then(|candidate| work.expected.bind(candidate))
            .map_err(SourceJobError::from);
        if matches!(result, Err(SourceJobError::Source(SourceError::Scheme))) {
            self.shared.stop();
        }
        {
            let closed = self.shared.gate();
            let mut phase = work.state.guard();
            if *closed || *phase == Phase::Cancelled {
                return;
            }
            *phase = Phase::Ready;
        }
        // Waking a caller happens outside all gates. The future rechecks them
        // when it claims the result, closing ready/send versus close/cancel races.
        let _ = work.reply.send(Reply {
            result,
            _slot: work.slot,
        });
    }
}

fn trace_digest(value: &impl serde::Serialize) -> String {
    serde_json::to_string(value)
        .map(|json| weaver_contracts::body_digest(&json))
        .unwrap_or_else(|_| "unavailable".to_owned())
}

pub(crate) fn governor_timing() -> bool {
    static ENABLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("WEAVER_TEST_GOVERNOR_TIMING").is_some())
}

fn trace_compile(phase: &str) {
    use std::time::{SystemTime, UNIX_EPOCH};
    let wall = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    eprintln!("weaver-governor-compile {phase} {wall}");
}
impl Drop for SourceInbox {
    fn drop(&mut self) {
        self.shared.stop();
    }
}
