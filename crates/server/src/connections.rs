// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! A permit follows each accepted TCP socket through TLS and HTTP/2 destruction.
use std::{
    io,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::{TcpListener, TcpStream},
    sync::{OwnedSemaphorePermit, Semaphore},
};
use tokio_stream::Stream;
use tokio_util::sync::PollSemaphore;
use tonic::transport::server::{Connected, TcpConnectInfo};

pub(crate) const MAX_CONNECTIONS: usize = 16;
pub(crate) const MAX_SOURCE_CONNECTIONS: usize = 4;

pub(crate) struct Incoming {
    listener: TcpListener,
    capacity: PollSemaphore,
    reserved: Option<OwnedSemaphorePermit>,
}
impl Incoming {
    pub(crate) fn new(listener: TcpListener, capacity: Arc<Semaphore>) -> Self {
        Self {
            listener,
            capacity: PollSemaphore::new(capacity),
            reserved: None,
        }
    }
}
impl Stream for Incoming {
    type Item = io::Result<Socket>;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let incoming = self.get_mut();
        if incoming.reserved.is_none() {
            match incoming.capacity.poll_acquire(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(None) => return Poll::Ready(None),
                Poll::Ready(Some(permit)) => incoming.reserved = Some(permit),
            }
        }
        match incoming.listener.poll_accept(cx) {
            Poll::Pending => Poll::Pending,
            Poll::Ready(result) => {
                let Some(permit) = incoming.reserved.take() else {
                    return Poll::Ready(Some(Err(io::Error::other("accept capacity missing"))));
                };
                Poll::Ready(Some(result.and_then(|(stream, _)| {
                    stream.set_nodelay(true)?;
                    Ok(Socket {
                        stream,
                        _permit: permit,
                    })
                })))
            }
        }
    }
}

pub(crate) struct Socket {
    stream: TcpStream,
    _permit: OwnedSemaphorePermit,
}
impl Connected for Socket {
    type ConnectInfo = TcpConnectInfo;
    fn connect_info(&self) -> Self::ConnectInfo {
        self.stream.connect_info()
    }
}
impl AsyncRead for Socket {
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_read(cx, buffer)
    }
}
impl AsyncWrite for Socket {
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffer: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().stream).poll_write(cx, buffer)
    }
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_flush(cx)
    }
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.get_mut().stream).poll_shutdown(cx)
    }
    fn is_write_vectored(&self) -> bool {
        self.stream.is_write_vectored()
    }
    fn poll_write_vectored(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buffers: &[io::IoSlice<'_>],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.get_mut().stream).poll_write_vectored(cx, buffers)
    }
}

#[cfg(test)]
#[path = "../tests/unit/connections.rs"]
mod tests;
