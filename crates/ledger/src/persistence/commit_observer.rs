// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Connection-local test instrumentation around the real native commit.
//! The normal server does not select this feature or install an observer.
/// Native transaction cut selected by an explicit test host.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cut {
    BeforeCommit,
    AfterCommit,
    BeforeRangePrepareCommit,
    AfterRangePrepareCommit,
    BeforeDeliveryCommit,
    AfterDeliveryCommit,
    BeforeSnapshotPublication,
    AfterSnapshotPublication,
}
/// Test decision; an unavailable result always poisons the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    Continue,
    Rollback,
    LoseAcknowledgment,
}
/// Per-connection observation, never a process-global production fault switch.
pub trait Observer: Send + Sync {
    /// Observe a real commit cut; native commit still owns its durable outcome.
    fn observe(&self, cut: Cut) -> Decision;
}
impl crate::Ledger {
    /// Test-host custody only; never serialized or accepted from an RPC request.
    pub fn observe_provider_commit(&mut self, observer: std::sync::Arc<dyn Observer>) {
        self.connection.commit_observer = Some(observer);
    }
}
