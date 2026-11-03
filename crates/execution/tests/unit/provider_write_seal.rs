// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

use super::{READING, SEALED, WRITING, WriteSeal};
use futures_executor::block_on;
use proptest::{
    prelude::{ProptestConfig, any},
    prop_assert, prop_assert_eq, proptest,
};
use std::task::Waker;
use std::{
    io,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    task::{Context, Poll},
};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};

struct Probe {
    bytes: Vec<u8>,
    step: usize,
    fail_after: usize,
    flush_pending: bool,
    flush_fails: bool,
    reads: usize,
}
impl AsyncRead for Probe {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        self.reads += 1;
        buf.put_slice(b"x");
        Poll::Ready(Ok(()))
    }
}
impl AsyncWrite for Probe {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let count = self
            .step
            .min(bytes.len())
            .min(self.fail_after.saturating_sub(self.bytes.len()));
        if count == 0 {
            return Poll::Ready(Err(io::ErrorKind::ConnectionReset.into()));
        }
        self.bytes.extend_from_slice(&bytes[..count]);
        Poll::Ready(Ok(count))
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.flush_fails {
            return Poll::Ready(Err(io::ErrorKind::BrokenPipe.into()));
        }
        if self.flush_pending {
            self.flush_pending = false;
            cx.waker().wake_by_ref();
            return Poll::Pending;
        }
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}
fn writer(length: usize, step: usize, fail_after: usize) -> WriteSeal<Probe> {
    WriteSeal::new(
        Probe {
            bytes: Vec::new(),
            step,
            fail_after,
            flush_pending: true,
            flush_fails: false,
            reads: 0,
        },
        length,
        Arc::new(AtomicU8::new(WRITING)),
    )
}
fn wire(body: &[u8]) -> Vec<u8> {
    let mut bytes =
        format!("POST / HTTP/1.1\r\ncontent-length: {}\r\n\r\n", body.len()).into_bytes();
    bytes.extend_from_slice(body);
    bytes
}
proptest! {
 #![proptest_config(ProptestConfig::with_cases(64))]
 #[test]
 fn accepted_bytes_require_flush_and_seal_rejects_every_tail(body in proptest::collection::vec(any::<u8>(),0..4096), step in 1usize..512) {
    let bytes=wire(&body);
    let mut io=writer(body.len(),step,usize::MAX);
    let mut cx=Context::from_waker(Waker::noop());
    let mut read=[0];
    prop_assert!(Pin::new(&mut io).poll_read(&mut cx,&mut ReadBuf::new(&mut read)).is_pending());
    prop_assert_eq!(io.inner.reads,0,"early response must stay gated");
    block_on(io.write_all(&bytes)).expect("partial write completion");
    prop_assert_eq!(io.phase.load(Ordering::Acquire),WRITING,"body EOF is not a flush");
    prop_assert!(Pin::new(&mut io).poll_flush(&mut cx).is_pending());
    prop_assert_eq!(io.phase.load(Ordering::Acquire),WRITING,"pending TLS flush is not completion");
    block_on(io.flush()).expect("TLS flush");
    prop_assert_eq!(io.phase.load(Ordering::Acquire),SEALED);
    prop_assert!(block_on(io.write_all(b"tail")).is_err());
    prop_assert_eq!(&io.inner.bytes,&bytes);
    prop_assert!(Pin::new(&mut io).poll_read(&mut cx,&mut ReadBuf::new(&mut read)).is_pending());
    io.phase.store(READING,Ordering::Release);
    prop_assert!(Pin::new(&mut io).poll_read(&mut cx,&mut ReadBuf::new(&mut read)).is_ready());
    prop_assert!(block_on(io.write_all(b"old worker")).is_err());
 }
 #[test]
 fn complete_plaintext_with_failed_tls_flush_never_mints_seal(body in proptest::collection::vec(any::<u8>(),0..4096)) {
    let bytes=wire(&body);
    let mut io=writer(body.len(),127,usize::MAX);
    block_on(io.write_all(&bytes)).expect("accepted plaintext");
    io.inner.flush_fails=true;
    prop_assert!(block_on(io.flush()).is_err());
    prop_assert_eq!(io.phase.load(Ordering::Acquire),WRITING);
    prop_assert_eq!(&io.inner.bytes,&bytes);
 }
 #[test]
 fn partial_failures_and_successful_short_flush_cannot_seal(body in proptest::collection::vec(any::<u8>(),1..2048), selector in any::<usize>()) {
    let bytes=wire(&body);let cut=selector%bytes.len();
    let mut io=writer(body.len(),7,cut);
    prop_assert!(block_on(io.write_all(&bytes)).is_err());
    block_on(io.flush()).expect("short flush");
    prop_assert_eq!(io.phase.load(Ordering::Acquire),WRITING);
    prop_assert_eq!(io.inner.bytes.len(),cut);
 }
}
#[test]
fn oversized_tail_is_rejected_before_inner_write() {
    let mut io = writer(1, 1024, usize::MAX);
    assert!(block_on(io.write_all(&wire(b"xx"))).is_err());
    assert!(io.inner.bytes.is_empty());
    assert_eq!(io.phase.load(Ordering::Acquire), WRITING);
}
