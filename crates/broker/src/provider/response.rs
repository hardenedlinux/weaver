// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Owned HTTP driver: dropped on failed commit; polled for reads only afterwards.
use super::{
    io_runtime::IoRuntime,
    observation::{ProviderTransportPhases, Stage, measure},
    write_seal::{READING, SEALED, WriteSeal},
};
use bytes::Bytes;
use http_body_util::Full;
use hyper::{
    body::{Body, Incoming},
    client::conn::http1,
};
use hyper_util::rt::TokioIo;
use std::{
    future::{Future, poll_fn},
    io::{self, Read},
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    task::{Context, Poll},
};
use tokio::{net::TcpStream, time::Instant};
use tokio_rustls::client::TlsStream;
use weaver_contracts::{Error, Result};
pub(super) type Connection =
    http1::Connection<TokioIo<WriteSeal<TlsStream<TcpStream>>>, Full<Bytes>>;
type ResponseFuture =
    Pin<Box<dyn Future<Output = hyper::Result<hyper::Response<Incoming>>> + Send>>;
pub(super) struct Driver {
    connection: Option<Connection>,
}
impl Driver {
    pub(super) fn new(connection: Connection) -> Self {
        Self {
            connection: Some(connection),
        }
    }
    fn pump(&mut self, cx: &mut Context<'_>) -> Result<()> {
        if let Some(connection) = &mut self.connection {
            match Pin::new(connection).poll(cx) {
                Poll::Ready(result) => {
                    self.connection = None;
                    result.map_err(|_| Error::Conflict("provider outcome unknown"))?;
                }
                Poll::Pending => {}
            }
        }
        Ok(())
    }
}
/// Affine local-drain/retirement result, never a settlement or response permit.
/// There is no spawned connection driver or cloneable HTTP sender.
pub(super) struct SealedRequest {
    driver: Driver,
    response: ResponseFuture,
    phase: Arc<AtomicU8>,
    runtime: Arc<IoRuntime>,
    deadline: Instant,
}
impl SealedRequest {
    pub(super) async fn finish_writing(
        mut driver: Driver,
        mut response: ResponseFuture,
        phase: Arc<AtomicU8>,
        runtime: Arc<IoRuntime>,
        deadline: Instant,
    ) -> Result<Self> {
        poll_fn(|cx| {
            // Queue exactly one request before driving its connection. Reads are
            // gated, so even early HTTP headers cannot finish this operation.
            if response.as_mut().poll(cx).is_ready() {
                return Poll::Ready(Err(Error::Conflict("response before request seal")));
            }
            if let Err(error) = driver.pump(cx) {
                return Poll::Ready(Err(error));
            }
            if phase.load(Ordering::Acquire) == SEALED {
                Poll::Ready(Ok(()))
            } else {
                Poll::Pending
            }
        })
        .await?;
        Ok(Self {
            driver,
            response,
            phase,
            runtime,
            deadline,
        })
    }
    /// Only called after dispatch_provider returned success (including commit).
    pub(super) fn wait_for_response_headers(
        mut self,
        phases: &std::cell::Cell<ProviderTransportPhases>,
    ) -> Result<Response> {
        self.phase
            .compare_exchange(SEALED, READING, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| Error::Conflict("provider writer not sealed"))?;
        let response = self.runtime.wait(
            self.deadline,
            measure(
                phases,
                Stage::Headers,
                poll_fn(|cx| {
                    if let Err(error) = self.driver.pump(cx) {
                        return Poll::Ready(Err(error));
                    }
                    self.response
                        .as_mut()
                        .poll(cx)
                        .map(|r| r.map_err(|_| Error::Conflict("provider outcome unknown")))
                }),
            ),
        )?;
        if response.status() != 200
            || response
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .is_none_or(|v| v.split(';').next().map(str::trim) != Some("text/event-stream"))
        {
            return Err(Error::Conflict(
                "provider did not return an admitted SSE stream",
            ));
        }
        Ok(Response {
            driver: self.driver,
            body: response.into_body(),
            pending: Bytes::new(),
            runtime: self.runtime,
            deadline: self.deadline,
        })
    }
}
pub(super) struct Response {
    driver: Driver,
    body: Incoming,
    pending: Bytes,
    runtime: Arc<IoRuntime>,
    deadline: Instant,
}
impl Read for Response {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        while self.pending.is_empty() {
            let frame = self
                .runtime
                .wait(
                    self.deadline,
                    poll_fn(|cx| {
                        self.driver.pump(cx)?;
                        Pin::new(&mut self.body).poll_frame(cx).map(|r| {
                            r.transpose()
                                .map_err(|_| Error::Conflict("provider outcome unknown"))
                        })
                    }),
                )
                .map_err(|_| io::Error::from(io::ErrorKind::ConnectionAborted))?;
            let Some(frame) = frame else { return Ok(0) };
            // Hyper parses chunk framing. Trailer metadata cannot authorize use.
            if let Ok(data) = frame.into_data() {
                self.pending = data;
            }
        }
        let count = bytes.len().min(self.pending.len());
        bytes[..count].copy_from_slice(&self.pending[..count]);
        self.pending = self.pending.slice(count..);
        Ok(count)
    }
}
