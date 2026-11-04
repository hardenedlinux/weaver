// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! The sole application writer: observe accepted plaintext, flush TLS, then seal.
use std::{
    io,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
pub(super) const WRITING: u8 = 0;
pub(super) const SEALED: u8 = 1;
pub(super) const READING: u8 = 2;

// Bounded outgoing delimiter observation, not a second HTTP codec. Hyper owns
// framing; a fixed Full body + explicit Content-Length forbids trailers/tails.
#[derive(Clone, Copy)]
struct Progress {
    window: u32,
    head: usize,
    body: usize,
    length: usize,
    in_body: bool,
}
impl Progress {
    fn accept(&mut self, mut bytes: &[u8]) -> io::Result<()> {
        while !self.in_body && !bytes.is_empty() {
            self.window = (self.window << 8) | u32::from(bytes[0]);
            self.head += 1;
            if self.head > 16384 {
                return Err(io::ErrorKind::InvalidData.into());
            }
            self.in_body = self.window == 0x0d0a0d0a;
            bytes = &bytes[1..];
        }
        self.body = self
            .body
            .checked_add(bytes.len())
            .filter(|n| *n <= self.length)
            .ok_or(io::ErrorKind::InvalidData)?;
        Ok(())
    }
    fn complete(&self) -> bool {
        self.in_body && self.body == self.length
    }
}
pub(super) struct WriteSeal<T> {
    inner: T,
    progress: Progress,
    phase: Arc<AtomicU8>,
}
impl<T> WriteSeal<T> {
    pub(super) fn new(inner: T, length: usize, phase: Arc<AtomicU8>) -> Self {
        Self {
            inner,
            progress: Progress {
                window: 0,
                head: 0,
                body: 0,
                length,
                in_body: false,
            },
            phase,
        }
    }
}
impl<T: AsyncRead + Unpin> AsyncRead for WriteSeal<T> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        // Even an early response stays unread until the sealed result's deciding
        // ledger scope has committed. No driver task exists outside this owner.
        if self.phase.load(Ordering::Acquire) != READING {
            return Poll::Pending;
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}
impl<T: AsyncWrite + Unpin> AsyncWrite for WriteSeal<T> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        if self.phase.load(Ordering::Acquire) != WRITING {
            return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
        }
        let mut offered = self.progress;
        if let Err(error) = offered.accept(bytes) {
            return Poll::Ready(Err(error));
        }
        match Pin::new(&mut self.inner).poll_write(cx, bytes) {
            Poll::Ready(Ok(n)) => {
                self.progress.accept(&bytes[..n])?;
                Poll::Ready(Ok(n))
            }
            other => other,
        }
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        match Pin::new(&mut self.inner).poll_flush(cx) {
            Poll::Ready(Ok(())) => {
                if self.progress.complete() && self.phase.load(Ordering::Acquire) == WRITING {
                    self.phase.store(SEALED, Ordering::Release);
                }
                Poll::Ready(Ok(()))
            }
            other => other,
        }
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.phase.load(Ordering::Acquire) == WRITING {
            return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
        }
        // TLS protocol closure is allowed; no HTTP/application write is allowed.
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
#[path = "../../tests/unit/provider_write_seal.rs"]
mod tests;
