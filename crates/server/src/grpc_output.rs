// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded outbound RPC custody; capacity waits precede durable release guards.
use crate::{
    encoding::{Frame, encode_frame},
    pb,
};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use weaver_broker::ProviderOutput;
use weaver_contracts::{Error, ProviderEvent, ProviderRoute, Result};
#[cfg(test)]
thread_local! {
    static HANDOFFS: std::cell::RefCell<Vec<(u64, u128)>> = const { std::cell::RefCell::new(Vec::new()) };
    static DELIVERIES: std::cell::RefCell<Vec<weaver_ledger::DeliveryObservation>> = const { std::cell::RefCell::new(Vec::new()) };
    static TRANSPORT: std::cell::Cell<Option<(weaver_broker::ProviderTransportPhases, u128)>> = const { std::cell::Cell::new(None) };
    static FIRST_QUEUE_TICKS: std::cell::Cell<Option<u128>> = const { std::cell::Cell::new(None) };
    static BROKER_PHASES: std::cell::Cell<[u128; 4]> = const { std::cell::Cell::new([0; 4]) };
    static ADMISSION_LEDGER: std::cell::Cell<Option<[weaver_ledger::TransactionTimings; 2]>> = const { std::cell::Cell::new(None) };
    static ENCODING_NANOS: std::cell::Cell<u128> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub(crate) fn append_admission_ledger(
    first_frame: &mut String,
    admission_ledger: [weaver_ledger::TransactionTimings; 2],
) {
    use std::fmt::Write;
    for timing in admission_ledger {
        for nanos in [
            timing.owner_gate_wait.nanos,
            timing.domain_wait.nanos,
            timing.transaction_begin.nanos,
            timing.domain_hold.nanos,
            timing.transaction_hold.nanos,
            timing.commit.nanos,
            timing.provider_cedar.nanos,
            timing.provider_publication_prepare.nanos,
            timing.provider_original_prepare.nanos,
            timing.provider_domain_prepare.nanos,
            timing.transaction_begin_poll.nanos,
            timing.transaction_begin_cpu.nanos,
            timing.transaction_begin_prepare.nanos,
            timing.transaction_begin_prepare_cpu.nanos,
            timing.commit_poll.nanos,
            timing.commit_cpu.nanos,
            timing.commit_sync.nanos,
        ] {
            let _ = write!(first_frame, " {nanos}");
        }
        let _ = write!(
            first_frame,
            " {} {} {} {} {} {} {} {} {}",
            timing.transaction_begin_poll.attempts,
            timing.transaction_begin_pending,
            timing.transaction_begin_cpu.attempts,
            timing.transaction_begin_prepare.attempts,
            timing.transaction_begin_prepare_cpu.attempts,
            timing.commit_poll.attempts,
            timing.commit_pending,
            timing.commit_cpu.attempts,
            timing.commit_sync.attempts,
        );
    }
}

#[cfg(test)]
pub(crate) fn take_encoding_nanos() -> u128 {
    ENCODING_NANOS.with(|total| total.replace(0))
}

#[cfg(test)]
pub(crate) fn take_handoffs() -> Vec<(u64, u128)> {
    HANDOFFS.with(|handoffs| std::mem::take(&mut *handoffs.borrow_mut()))
}

#[cfg(test)]
pub(crate) fn take_deliveries() -> Vec<weaver_ledger::DeliveryObservation> {
    DELIVERIES.with(|rows| std::mem::take(&mut *rows.borrow_mut()))
}

#[cfg(test)]
pub(crate) fn take_transport() -> Option<(weaver_broker::ProviderTransportPhases, u128)> {
    TRANSPORT.with(|phases| phases.take())
}

#[cfg(test)]
pub(crate) fn take_first_queue_ticks() -> Option<u128> {
    FIRST_QUEUE_TICKS.with(|slot| slot.take())
}

#[cfg(test)]
pub(crate) fn take_broker_phases() -> [u128; 4] {
    BROKER_PHASES.with(|phases| phases.replace([0; 4]))
}

#[cfg(test)]
pub(crate) fn take_admission_ledger() -> Option<[weaver_ledger::TransactionTimings; 2]> {
    ADMISSION_LEDGER.with(|phases| phases.take())
}

/// Only Output constructs the packet. Other server owners cannot inspect or
/// modify its bytes before the deciding receiver consumes the proof.
pub(crate) struct InertFrame {
    frame: Option<pb::ProviderFrame>,
    proof: weaver_ledger::DeliveryFrame,
}
impl InertFrame {
    pub(crate) fn poll(
        &mut self,
        cursor: &mut weaver_ledger::DeliveryCursor,
        cx: &std::task::Context<'_>,
    ) -> std::task::Poll<Result<pb::ProviderFrame>> {
        cursor.poll(&self.proof, cx, &mut self.frame)
    }
    #[cfg(all(test, unix))]
    pub(crate) fn acknowledged(&self) -> bool {
        self.proof.acknowledged()
    }
}
impl std::fmt::Debug for InertFrame {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("InertFrame").finish_non_exhaustive()
    }
}
pub(crate) const DELIVERY_QUEUE_CAPACITY: usize = 2;
type Sender = mpsc::Sender<std::result::Result<InertFrame, tonic::Status>>;

pub(crate) struct Output {
    pub telemetry: std::sync::Arc<weaver_telemetry::Metrics>,
    pub sender: Sender,
    pub pending: Option<weaver_ledger::DeliveryProducer>,
    pub deliveries: std::collections::VecDeque<crate::grpc_delivery_producer::PendingDelivery>,
    pub cancelled: CancellationToken,
    pub shutdown: CancellationToken,
    pub runtime: tokio::runtime::Handle,
}
pub(crate) struct PreparedFrame {
    frame: pb::ProviderFrame,
    first: u64,
    rows: usize,
}
impl ProviderOutput for Output {
    #[cfg(test)]
    fn observe_transport(&self, phases: weaver_broker::ProviderTransportPhases) {
        let timestamp = weaver_ledger::persistence::provider_observation_nanos();
        TRANSPORT.with(|slot| slot.set(Some((phases, timestamp))));
    }
    #[cfg(test)]
    fn observe_admission(
        &self,
        enqueue_nanos: u128,
        consume_nanos: u128,
        ledger: [weaver_ledger::TransactionTimings; 2],
    ) {
        BROKER_PHASES.with(|phases| phases.set([enqueue_nanos, consume_nanos, 0, 0]));
        ADMISSION_LEDGER.with(|phases| phases.set(Some(ledger)));
    }
    #[cfg(test)]
    fn observe_dispatch(&self, prepare_nanos: u128, dispatch_nanos: u128) {
        BROKER_PHASES.with(|phases| {
            let [enqueue, consume, ..] = phases.get();
            phases.set([enqueue, consume, prepare_nanos, dispatch_nanos]);
        });
    }
    type PreparedFrame = PreparedFrame;
    type Slot = mpsc::OwnedPermit<std::result::Result<InertFrame, tonic::Status>>;
    #[cfg(test)]
    fn prepare_ranges_separately(&self) -> bool {
        std::env::var_os("WEAVER_TEST_SINGLE_RANGE_PREPARE").is_some()
    }
    #[cfg(test)]
    fn release_ranges_separately(&self) -> bool {
        std::env::var_os("WEAVER_TEST_SINGLE_RANGE_COMMIT").is_some()
    }
    fn stopped(&self) -> bool {
        self.cancelled.is_cancelled() || self.shutdown.is_cancelled() || self.sender.is_closed()
    }
    fn reserve(&mut self) -> Result<Self::Slot> {
        self.runtime
            .block_on(async {
                tokio::select! {
                    biased;
                    _=self.cancelled.cancelled()=>{
                        #[cfg(all(test, unix))]
                        backpressure_tests::cancelled();
                        Err(Error::Conflict("RPC cancelled"))
                    },
                    _=self.shutdown.cancelled()=>Err(Error::Conflict("server closing")),
                    slot=tokio::time::timeout(std::time::Duration::from_secs(1),{
                        #[cfg(all(test, unix))]
                        { backpressure_tests::observe(self.sender.clone().reserve_owned()) }
                        #[cfg(not(all(test, unix)))]
                        { self.sender.clone().reserve_owned() }
                    })=>
                        slot.map_err(|_|{
                            #[cfg(all(test, unix))]
                            backpressure_tests::expired();
                            Error::Conflict("RPC flow control deadline")
                        })?.map_err(|_|Error::Conflict("RPC receiver closed")),
                }
            })
            .inspect_err(|_| {
                self.telemetry
                    .record(weaver_telemetry::Signal::QueueWaitFailed)
            })
    }
    fn reserve_for_delivery(
        &mut self,
        ledger: &mut weaver_ledger::Ledger,
        permit: &weaver_ledger::ProviderDispatch,
        format: &str,
    ) -> Result<Self::Slot> {
        self.reserve_guarded(ledger, permit, format)
    }
    fn drain_delivery(
        &mut self,
        ledger: &mut weaver_ledger::Ledger,
        permit: &weaver_ledger::ProviderDispatch,
        format: &str,
    ) -> Result<()> {
        self.drain_deliveries(ledger, permit, format)
    }
    fn service_delivery(
        &mut self,
        ledger: &mut weaver_ledger::Ledger,
        permit: &weaver_ledger::ProviderDispatch,
        format: &str,
    ) -> Result<Option<tokio::time::Instant>> {
        self.progress_deliveries(ledger, permit, format)?;
        Ok(self.deliveries.front().map(|entry| entry.deadline.into()))
    }
    fn poll_delivery_ready(&self, cx: &mut std::task::Context<'_>) -> std::task::Poll<()> {
        self.deliveries
            .front()
            .map_or(std::task::Poll::Pending, |entry| {
                entry.receipt.poll_progress_ready(cx)
            })
    }
    fn prepare(
        route: &ProviderRoute,
        model: &str,
        events: &[ProviderEvent],
        format: &str,
    ) -> Result<PreparedFrame> {
        #[cfg(test)]
        let started = std::time::Instant::now();
        let frame = encode_frame(Frame {
            target: &route.target,
            model,
            events,
            encoding: match format {
                "arrow" => pb::Encoding::ArrowIpc,
                "protobuf" => pb::Encoding::Protobuf,
                _ => return Err(Error::Invalid("response encoding")),
            },
        })?;
        #[cfg(test)]
        ENCODING_NANOS.with(|total| total.set(total.get() + started.elapsed().as_nanos()));
        Ok(PreparedFrame {
            frame,
            first: events[0].sequence,
            rows: events.len(),
        })
    }
    fn emit(
        &mut self,
        slot: Self::Slot,
        prepared: PreparedFrame,
        receipt: weaver_ledger::ProviderDelivery,
    ) -> Result<()> {
        if self.stopped()
            || self.pending.is_some()
            || self.deliveries.len() > DELIVERY_QUEUE_CAPACITY
            || receipt.interval()
                != (weaver_ledger::DeliveryInterval {
                    first: prepared.first,
                    rows: prepared.rows as u64,
                })
        {
            return Err(Error::Conflict("RPC cancelled or foreign delivery frame"));
        }
        let (producer, proof) = receipt.split();
        self.pending = Some(producer);
        #[cfg(test)]
        if prepared.first == 0 && std::env::var_os("WEAVER_TEST_PROVIDER_SCOPE_TRACE").is_some() {
            FIRST_QUEUE_TICKS.with(|slot| {
                slot.set(Some(
                    weaver_ledger::persistence::provider_observation_nanos(),
                ));
            });
        }
        #[cfg(test)]
        if std::env::var_os("WEAVER_TEST_PROVIDER_SCOPE_TRACE").is_some()
            && let Ok(time) = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        {
            HANDOFFS.with(|rows| {
                let mut rows = rows.borrow_mut();
                if rows.len() < 64 {
                    rows.push((prepared.first, time.as_nanos()));
                }
            });
        }
        slot.send(Ok(InertFrame {
            frame: Some(prepared.frame),
            proof,
        }));
        self.telemetry
            .record(weaver_telemetry::Signal::ResponseFramesQueued);
        #[cfg(all(test, unix))]
        backpressure_tests::enqueued(prepared.first, prepared.rows);
        Ok(())
    }
    fn finish_delivery(
        &mut self,
        ledger: &mut weaver_ledger::Ledger,
        permit: &weaver_ledger::ProviderDispatch,
        format: &str,
    ) -> Result<()> {
        let receipt = self
            .pending
            .take()
            .ok_or(Error::Conflict("delivery not staged"))?;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(1);
        #[cfg(test)]
        if std::env::var_os("WEAVER_TEST_FORCE_DELIVERY_REFRESH").is_some() {
            ledger.refresh_provider_delivery(permit, &receipt, format)?;
        }
        receipt.acknowledge(deadline)?;
        self.deliveries
            .push_back(crate::grpc_delivery_producer::PendingDelivery::new(
                receipt, deadline,
            ));
        self.progress_deliveries(ledger, permit, format)
    }
}

#[cfg(all(test, unix))]
#[path = "../tests/unit/output_backpressure.rs"]
pub(crate) mod backpressure_tests;

pub(crate) async fn observe_reservation<F: std::future::Future>(future: F) -> F::Output {
    #[cfg(all(test, unix))]
    {
        backpressure_tests::observe(future).await
    }
    #[cfg(not(all(test, unix)))]
    {
        future.await
    }
}
#[cfg(test)]
pub(crate) fn record_delivery(receipt: &weaver_ledger::DeliveryProducer) {
    if let Some(observation) = receipt.observation() {
        DELIVERIES.with(|rows| {
            let mut rows = rows.borrow_mut();
            if rows.len() < 64 {
                rows.push(observation);
            }
        });
    }
}
