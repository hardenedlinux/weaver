// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! HTTP body projection after the same deciding cursor used by RPC.
use crate::{delivery_payload::Payload, grpc_delivery::ResponseStream};
use bytes::Bytes;
use std::{
    pin::Pin,
    task::{Context, Poll},
};
use tokio_stream::Stream;
use tonic::Status;

pub(crate) struct SseStream(pub(crate) ResponseStream);
impl Stream for SseStream {
    type Item = Result<Bytes, Status>;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        Pin::new(&mut this.0).poll_payload(cx).map(|next| {
            next.map(|result| {
                result.and_then(|payload| match payload {
                    Payload::Sse(bytes) => Ok(Bytes::from(bytes)),
                    Payload::Rpc(_) => Err(Status::internal("response transport mismatch")),
                })
            })
        })
    }
}
