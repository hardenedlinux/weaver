// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded source compilation on the caller's tracked blocking owner.
//! Only Rust-owned data crosses this lane; a compiler may keep a non-Send VM.
use super::SourceJobError;
use crate::{BoundSource, OwnedSource, SourceExpectation};
use std::sync::{Arc, Mutex, MutexGuard};
use tokio::sync::{OwnedSemaphorePermit, oneshot};
use tokio_util::sync::CancellationToken;
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Phase {
    Queued,
    Running,
    Ready,
    Delivered,
    Cancelled,
}
pub(super) struct Shared {
    pub(super) closed: Mutex<bool>,
    pub(super) shutdown: CancellationToken,
}
impl Shared {
    pub(super) fn gate(&self) -> MutexGuard<'_, bool> {
        match self.closed.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                *guard = true;
                guard
            }
        }
    }
    pub(super) fn stop(&self) {
        *self.gate() = true;
        self.shutdown.cancel();
    }
}
pub(super) struct State {
    pub(super) phase: Mutex<Phase>,
}
impl State {
    pub(super) fn guard(&self) -> MutexGuard<'_, Phase> {
        match self.phase.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                let mut guard = poisoned.into_inner();
                *guard = Phase::Cancelled;
                guard
            }
        }
    }
}
pub(super) struct Reply {
    pub(super) result: Result<BoundSource, SourceJobError>,
    pub(super) _slot: OwnedSemaphorePermit,
}
pub(super) struct Work {
    pub(super) original: OwnedSource,
    pub(super) expected: SourceExpectation,
    pub(super) state: Arc<State>,
    pub(super) reply: oneshot::Sender<Reply>,
    pub(super) slot: OwnedSemaphorePermit,
    pub(super) cancel: CancellationToken,
}
/// Fixed Governor facts, detached from the authoritative ledger cut.
#[derive(serde::Serialize)]
pub struct GovernorCut {
    pub nodes: Vec<String>,
    pub edges: Vec<(String, String)>,
    pub complete: Vec<String>,
    pub available: Vec<String>,
    pub pending: Vec<String>,
    pub choice_arms: Vec<String>,
    pub choice_join: Vec<String>,
    pub choice_result: Vec<String>,
    pub choice_decided: Vec<String>,
    pub nested_selectors: Vec<[String; 3]>,
    pub nested_results: Vec<(String, String)>,
    pub nested_decisions: Vec<(String, String)>,
}
/// Inert observations evaluated by the existing linked Scheme owner.
#[derive(serde::Serialize)]
pub enum Derivation {
    Governor(Box<GovernorCut>),
    FactImpact {
        root: String,
        dependencies: Vec<(String, String)>,
    },
}
pub(super) enum Command {
    Derive {
        input: Derivation,
        reply: oneshot::Sender<Result<Vec<String>, crate::SourceError>>,
        _slot: OwnedSemaphorePermit,
        queued: Option<std::time::Instant>,
    },
    Compile(Box<Work>),
    Stop,
}
