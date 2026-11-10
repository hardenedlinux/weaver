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
/// Immutable graph owned by one prepared Workflow publication.
pub struct GovernorTopology {
    pub nodes: Vec<String>,
    pub edges: Vec<(String, String)>,
    pub choice_arms: Vec<String>,
    pub choice_join: Vec<String>,
    pub nested_selectors: Vec<[String; 3]>,
}

/// Complete mutable facts detached from the authoritative ledger cut.
pub struct GovernorCut {
    pub topology: Arc<GovernorTopology>,
    pub complete: Vec<String>,
    pub available: Vec<String>,
    pub pending: Vec<String>,
    pub choice_result: Vec<String>,
    pub choice_decided: Vec<String>,
    pub nested_results: Vec<(String, String)>,
    pub nested_decisions: Vec<(String, String)>,
}
impl serde::Serialize for GovernorCut {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        // Keep the semantic cut digest independent of the transport and its binding.
        let mut cut = serializer.serialize_struct("GovernorCut", 12)?;
        cut.serialize_field("nodes", &self.topology.nodes)?;
        cut.serialize_field("edges", &self.topology.edges)?;
        cut.serialize_field("complete", &self.complete)?;
        cut.serialize_field("available", &self.available)?;
        cut.serialize_field("pending", &self.pending)?;
        cut.serialize_field("choice_arms", &self.topology.choice_arms)?;
        cut.serialize_field("choice_join", &self.topology.choice_join)?;
        cut.serialize_field("choice_result", &self.choice_result)?;
        cut.serialize_field("choice_decided", &self.choice_decided)?;
        cut.serialize_field("nested_selectors", &self.topology.nested_selectors)?;
        cut.serialize_field("nested_results", &self.nested_results)?;
        cut.serialize_field("nested_decisions", &self.nested_decisions)?;
        cut.end()
    }
}
/// Inert observations evaluated by the existing linked Scheme owner.
#[derive(serde::Serialize)]
pub enum Derivation {
    Composition(Box<crate::SourceComposition>),
    Governor(Box<GovernorCut>),
    FactImpact {
        root: String,
        dependencies: Vec<(String, String)>,
    },
}
/// Detached node identities. Indices belong to the topology of this Governor request.
#[derive(Debug, PartialEq, Eq)]
pub enum DerivationOutput {
    Source(crate::OwnedSource),
    Nodes(Vec<String>),
    Indices(Vec<usize>),
}
pub(super) struct DerivationReply {
    pub(super) result: Result<DerivationOutput, crate::SourceError>,
    /// Enqueued, owner start, derivation finished, and reply submission.
    pub(super) timing: Option<[std::time::Instant; 4]>,
}
pub(super) enum Command {
    Derive {
        input: Derivation,
        reply: oneshot::Sender<DerivationReply>,
        _slot: OwnedSemaphorePermit,
        queued: Option<std::time::Instant>,
    },
    Compile(Box<Work>),
    Stop,
}
