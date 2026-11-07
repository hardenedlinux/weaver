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
                crate::Derivation::Governor(cut) => derive(owner, cut),
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
        mut derive: impl FnMut(&mut C, &crate::Derivation) -> Result<Vec<String>, SourceError>,
    ) {
        while let Some(command) = self.receiver.blocking_recv() {
            if *self.shared.gate() {
                break;
            }
            match command {
                Command::Stop => break,
                Command::Compile(work) => self.execute(*work, &mut |original, cancel| {
                    compile(&mut owner, original, cancel)
                }),
                Command::Derive {
                    input,
                    reply,
                    _slot,
                } => {
                    self.execute_derivation(reply, || derive(&mut owner, &input));
                }
            }
            if *self.shared.gate() {
                break;
            }
        }
        drop(owner);
    }
    fn execute_derivation(
        &self,
        reply: tokio::sync::oneshot::Sender<Result<Vec<String>, SourceError>>,
        derive: impl FnOnce() -> Result<Vec<String>, SourceError>,
    ) {
        if reply.is_closed() {
            return;
        }
        let result = derive();
        if matches!(result, Err(SourceError::Scheme)) {
            self.shared.stop();
        }
        let _ = reply.send(result);
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

impl Drop for SourceInbox {
    fn drop(&mut self) {
        self.shared.stop();
    }
}
