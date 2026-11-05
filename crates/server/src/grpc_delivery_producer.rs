// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded producer lifecycle. Capacity waiting and requalification hold no SQL scope.
use crate::grpc_output::{InertFrame, Output, observe_reservation};
use std::{
    future::{Future, poll_fn},
    task::Poll,
    time::{Duration, Instant},
};
use weaver_broker::ProviderOutput;
use weaver_contracts::{Error, Result};
use weaver_ledger::{DeliveryProducer, DeliveryWait, Ledger, ProviderDispatch};

pub(crate) struct PendingDelivery {
    receipt: DeliveryProducer,
    deadline: Instant,
}
impl PendingDelivery {
    pub(crate) fn new(receipt: DeliveryProducer, deadline: Instant) -> Self {
        Self { receipt, deadline }
    }
}
impl Output {
    pub(crate) fn progress_deliveries(
        &mut self,
        ledger: &mut Ledger,
        permit: &ProviderDispatch,
        format: &str,
    ) -> Result<()> {
        while let Some(first) = self.deliveries.front() {
            match first.receipt.progress()? {
                Some(DeliveryWait::Accepted) => self.completed_delivery(),
                Some(DeliveryWait::Refresh) => {
                    ledger.refresh_provider_delivery(permit, &first.receipt, format)?
                }
                None => break,
            }
        }
        Ok(())
    }
    fn completed_delivery(&mut self) {
        let _completed = self.deliveries.pop_front().expect("pending delivery");
        #[cfg(test)]
        crate::grpc_output::record_delivery(&_completed.receipt);
    }
    pub(crate) fn drain_deliveries(
        &mut self,
        ledger: &mut Ledger,
        permit: &ProviderDispatch,
        format: &str,
    ) -> Result<()> {
        while let Some(first) = self.deliveries.front() {
            match first.receipt.wait(|| self.stopped(), first.deadline)? {
                DeliveryWait::Refresh => {
                    ledger.refresh_provider_delivery(permit, &first.receipt, format)?
                }
                DeliveryWait::Accepted => self.completed_delivery(),
            }
        }
        Ok(())
    }
    pub(crate) fn reserve_guarded(
        &mut self,
        ledger: &mut Ledger,
        permit: &ProviderDispatch,
        format: &str,
    ) -> Result<tokio::sync::mpsc::OwnedPermit<std::result::Result<InertFrame, tonic::Status>>>
    {
        self.progress_deliveries(ledger, permit, format)?;
        if self.deliveries.is_empty() {
            return self.reserve();
        }
        let result = self.reserve_with_pending(ledger, permit, format);
        #[cfg(all(test, unix))]
        if result.is_err() {
            if self.stopped() {
                crate::grpc_output::backpressure_tests::cancelled();
            } else {
                crate::grpc_output::backpressure_tests::expired();
            }
        }
        result
    }
    fn reserve_with_pending(
        &mut self,
        ledger: &mut Ledger,
        permit: &ProviderDispatch,
        format: &str,
    ) -> Result<tokio::sync::mpsc::OwnedPermit<std::result::Result<InertFrame, tonic::Status>>>
    {
        let deadline = Instant::now() + Duration::from_secs(1);
        let runtime = self.runtime.clone();
        let reservation = observe_reservation(self.sender.clone().reserve_owned());
        let mut reservation = std::pin::pin!(reservation);
        let mut refresh = false;
        loop {
            if self.stopped() || Instant::now() >= deadline {
                return Err(Error::Conflict("RPC flow control deadline"));
            }
            // Poll the SAME real capacity future before joining a receiver wake.
            // Its Pending/Ready observations retain the original backpressure cut.
            let polled = runtime.block_on(poll_fn(|cx| Poll::Ready(reservation.as_mut().poll(cx))));
            if refresh {
                let first = self
                    .deliveries
                    .front()
                    .ok_or(Error::Conflict("delivery owner absent"))?;
                ledger.refresh_provider_delivery(permit, &first.receipt, format)?;
                refresh = false;
            }
            match polled {
                Poll::Ready(slot) => {
                    self.progress_deliveries(ledger, permit, format)?;
                    return slot.map_err(|_| Error::Conflict("RPC receiver closed"));
                }
                Poll::Pending => {
                    let first = self
                        .deliveries
                        .front()
                        .ok_or(Error::Conflict("capacity without pending owner"))?;
                    match first
                        .receipt
                        .wait(|| self.stopped(), deadline.min(first.deadline))?
                    {
                        DeliveryWait::Accepted => self.completed_delivery(),
                        DeliveryWait::Refresh => refresh = true,
                    }
                }
            }
        }
    }
}
