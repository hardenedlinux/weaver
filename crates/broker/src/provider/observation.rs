// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Per-invocation stage accounting, including failed/dropped futures. It is
//! neither a no-execution certificate nor authority to settle any reservation.
use std::{cell::Cell, time::Instant};
/// Local elapsed time and outcome of one polled transport stage.
#[derive(Clone, Copy, Default, Debug)]
pub struct TransportStage {
    pub nanos: u64,
    pub attempted: bool,
    pub completed: bool,
}
/// Ordered measurements for one guarded invocation; never settlement evidence.
#[derive(Clone, Copy, Default, Debug)]
pub struct ProviderTransportPhases {
    pub connect: TransportStage,
    pub tls: TransportStage,
    pub write: TransportStage,
    pub headers: TransportStage,
}
#[derive(Clone, Copy)]
pub(super) enum Stage {
    Connect,
    Tls,
    Write,
    Headers,
}
struct Measurement<'a> {
    phases: &'a Cell<ProviderTransportPhases>,
    stage: Stage,
    entered: Instant,
    completed: bool,
}
impl Drop for Measurement<'_> {
    fn drop(&mut self) {
        let mut phases = self.phases.get();
        let value = TransportStage {
            nanos: u64::try_from(self.entered.elapsed().as_nanos()).unwrap_or(u64::MAX),
            attempted: true,
            completed: self.completed,
        };
        match self.stage {
            Stage::Connect => phases.connect = value,
            Stage::Tls => phases.tls = value,
            Stage::Write => phases.write = value,
            Stage::Headers => phases.headers = value,
        }
        self.phases.set(phases);
    }
}
pub(super) async fn measure<T, E>(
    phases: &Cell<ProviderTransportPhases>,
    stage: Stage,
    operation: impl std::future::Future<Output = Result<T, E>>,
) -> Result<T, E> {
    let mut sample = Measurement {
        phases,
        stage,
        entered: Instant::now(),
        completed: false,
    };
    let result = operation.await;
    sample.completed = result.is_ok();
    result
}
