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
use weaver_contracts::{Error, ProviderEvent, ProviderRoute, Result};
use weaver_execution::ProviderOutput;
pub(crate) struct Output {
    pub telemetry: std::sync::Arc<weaver_telemetry::Metrics>,
    pub sender: mpsc::Sender<std::result::Result<pb::ProviderFrame, tonic::Status>>,
    pub cancelled: CancellationToken,
    pub shutdown: CancellationToken,
    pub runtime: tokio::runtime::Handle,
}
pub(crate) struct PreparedFrame {
    frame: pb::ProviderFrame,
    #[cfg(all(test, unix))]
    first: u64,
    #[cfg(all(test, unix))]
    rows: usize,
}
impl ProviderOutput for Output {
    type PreparedFrame = PreparedFrame;
    type Slot = mpsc::OwnedPermit<std::result::Result<pb::ProviderFrame, tonic::Status>>;
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
    fn prepare(
        route: &ProviderRoute,
        model: &str,
        events: &[ProviderEvent],
        format: &str,
    ) -> Result<PreparedFrame> {
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
        Ok(PreparedFrame {
            frame,
            #[cfg(all(test, unix))]
            first: events[0].sequence,
            #[cfg(all(test, unix))]
            rows: events.len(),
        })
    }
    fn emit(&mut self, slot: Self::Slot, prepared: PreparedFrame) -> Result<()> {
        if self.stopped() {
            return Err(Error::Conflict("RPC cancelled before release"));
        }
        slot.send(Ok(prepared.frame));
        self.telemetry
            .record(weaver_telemetry::Signal::ResponseFramesQueued);
        #[cfg(all(test, unix))]
        backpressure_tests::enqueued(prepared.first, prepared.rows);
        Ok(())
    }
}

#[cfg(all(test, unix))]
#[path = "../tests/unit/output_backpressure.rs"]
mod backpressure_tests;
