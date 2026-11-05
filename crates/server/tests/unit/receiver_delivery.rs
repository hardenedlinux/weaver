// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Test-build async pause after commit acknowledgment, before the deciding poll.
use std::{
    future::Future,
    pin::Pin,
    sync::atomic::{AtomicBool, Ordering},
    task::{Context, Poll},
    time::Duration,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tonic::Status;

static USED: AtomicBool = AtomicBool::new(false);
type Observation = Pin<Box<dyn Future<Output = Result<(), Status>> + Send>>;
#[derive(Default)]
pub(crate) struct ReceiverPause {
    future: Option<Observation>,
    done: bool,
}
impl ReceiverPause {
    pub(crate) fn poll(
        &mut self,
        acknowledged: bool,
        cx: &mut Context<'_>,
    ) -> Poll<Result<(), Status>> {
        if self.done || !acknowledged {
            return Poll::Ready(Ok(()));
        }
        if self.future.is_none() {
            if std::env::var_os("WEAVER_TEST_RECEIVER_PAUSE").is_none()
                || USED.swap(true, Ordering::SeqCst)
            {
                self.done = true;
                return Poll::Ready(Ok(()));
            }
            self.future = Some(Box::pin(observe()));
        }
        match self
            .future
            .as_mut()
            .expect("receiver observation")
            .as_mut()
            .poll(cx)
        {
            Poll::Ready(result) => {
                self.done = true;
                self.future = None;
                Poll::Ready(result)
            }
            Poll::Pending => Poll::Pending,
        }
    }
}
async fn observe() -> Result<(), Status> {
    let path = std::env::var("WEAVER_TEST_COMMIT_SOCKET")
        .map_err(|_| Status::internal("observer path"))?;
    tokio::time::timeout(Duration::from_secs(3), async {
        let mut socket = tokio::net::UnixStream::connect(path)
            .await
            .map_err(|_| Status::internal("observer connect"))?;
        socket
            .write_all(b"BeforeReceiverHandoff 0\n")
            .await
            .map_err(|_| Status::internal("observer delivery"))?;
        let mut command = [0];
        socket
            .read_exact(&mut command)
            .await
            .map_err(|_| Status::internal("observer resume"))?;
        if command[0] != b'c' {
            return Err(Status::cancelled("observer rejected"));
        }
        Ok(())
    })
    .await
    .map_err(|_| Status::deadline_exceeded("original receiver observation window"))?
}

static INERT_SEEN: AtomicBool = AtomicBool::new(false);
impl ReceiverPause {
    pub(crate) fn blocked(&self) {
        if std::env::var_os("WEAVER_TEST_DELIVERY_OBSERVE").is_some()
            && !INERT_SEEN.swap(true, Ordering::SeqCst)
        {
            tokio::spawn(async {
                if let Ok(path) = std::env::var("WEAVER_TEST_COMMIT_SOCKET")
                    && let Ok(mut socket) = tokio::net::UnixStream::connect(path).await
                {
                    let _ = socket.write_all(b"InertFrameBlocked 0\n").await;
                }
            });
        }
    }
}
