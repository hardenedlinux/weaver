// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Only this receiver transfers response bytes to Tonic; queued frames are inert.
use crate::grpc_output::InertFrame;
use crate::pb;
use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};
use tokio::sync::mpsc;
use tokio_stream::{Stream, wrappers::ReceiverStream};
use tokio_util::sync::CancellationToken;
use tonic::Status;
use weaver_ledger::DeliveryCursor;

/// One mutable cursor and one receiver. Neither can be cloned by an RPC worker.
pub struct ResponseStream {
    receiver: ReceiverStream<Result<InertFrame, Status>>,
    staged: Option<InertFrame>,
    cursor: DeliveryCursor,
    cancelled: CancellationToken,
    shutdown: Pin<Box<tokio_util::sync::WaitForCancellationFutureOwned>>,
    ended: bool,
    #[cfg(all(test, unix))]
    pause: receiver_tests::ReceiverPause,
}
impl ResponseStream {
    pub(crate) fn new(
        receiver: mpsc::Receiver<Result<InertFrame, Status>>,
        cursor: DeliveryCursor,
        cancelled: CancellationToken,
        shutdown: tokio_util::sync::WaitForCancellationFutureOwned,
    ) -> Self {
        Self {
            receiver: ReceiverStream::new(receiver),
            staged: None,
            cursor,
            cancelled,
            shutdown: Box::pin(shutdown),
            ended: false,
            #[cfg(all(test, unix))]
            pause: Default::default(),
        }
    }
}
impl Stream for ResponseStream {
    type Item = Result<pb::ProviderFrame, Status>;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        if this.ended || this.shutdown.as_mut().poll(cx).is_ready() || this.cancelled.is_cancelled()
        {
            this.cancelled.cancel();
            this.receiver.close();
            this.staged = None;
            return Poll::Ready(None);
        }
        if this.staged.is_none() {
            match Pin::new(&mut this.receiver).poll_next(cx) {
                Poll::Ready(Some(Ok(frame))) => this.staged = Some(frame),
                Poll::Ready(Some(Err(error))) => {
                    this.ended = true;
                    return Poll::Ready(Some(Err(error)));
                }
                Poll::Ready(None) => return Poll::Ready(None),
                Poll::Pending => return Poll::Pending,
            }
        }
        let frame = this.staged.as_mut().expect("staged receiver frame");
        #[cfg(all(test, unix))]
        match this.pause.poll(frame.acknowledged(), cx) {
            Poll::Pending => return Poll::Pending,
            Poll::Ready(Err(error)) => {
                this.cancelled.cancel();
                this.staged = None;
                this.ended = true;
                return Poll::Ready(Some(Err(error)));
            }
            Poll::Ready(Ok(())) => {}
        }
        match frame.poll(&mut this.cursor, cx) {
            Poll::Ready(Ok(frame)) => {
                this.staged = None;
                Poll::Ready(Some(Ok(frame)))
            }
            Poll::Pending => {
                #[cfg(all(test, unix))]
                if !frame.acknowledged() {
                    this.pause.blocked();
                }
                Poll::Pending
            }
            Poll::Ready(Err(error)) => {
                this.cancelled.cancel();
                this.receiver.close();
                this.staged = None;
                this.ended = true;
                Poll::Ready(Some(Err(Status::failed_precondition(format!(
                    "delivery authority changed; original reservation retained: {}",
                    crate::grpc_contracts::rejection_reason(&error),
                )))))
            }
        }
    }
}
impl Drop for ResponseStream {
    fn drop(&mut self) {
        self.cancelled.cancel();
    }
}

#[cfg(all(test, unix))]
#[path = "../tests/unit/receiver_delivery.rs"]
mod receiver_tests;
