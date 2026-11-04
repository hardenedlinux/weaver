// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Incoming, Socket};
use std::{pin::Pin, sync::Arc, task::Poll, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
};
use tokio_stream::{Stream, StreamExt};
use tonic::transport::server::Connected;

async fn next(incoming: &mut Incoming) -> Socket {
    tokio::time::timeout(Duration::from_secs(3), incoming.next())
        .await
        .expect("accept deadline")
        .expect("listener open")
        .expect("socket")
}
async fn pending(incoming: &mut Incoming) {
    std::future::poll_fn(|cx| {
        assert!(matches!(
            Pin::new(&mut *incoming).poll_next(cx),
            Poll::Pending
        ));
        Poll::Ready(())
    })
    .await;
}

#[tokio::test]
async fn pending_listener_reservation_is_released_on_drop() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let capacity = Arc::new(Semaphore::new(1));
    let mut incoming = Incoming::new(listener, capacity.clone());
    pending(&mut incoming).await;
    assert_eq!(capacity.available_permits(), 0);
    drop(incoming);
    assert_eq!(capacity.available_permits(), 1);
}

#[tokio::test]
async fn tcp_socket_owns_capacity_until_destruction_and_preserves_io_and_peer_identity() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("listener");
    let address = listener.local_addr().expect("address");
    let capacity = Arc::new(Semaphore::new(1));
    let mut incoming = Incoming::new(listener, capacity.clone());
    let mut first = TcpStream::connect(address).await.expect("first");
    let mut accepted = next(&mut incoming).await;
    assert_eq!(
        accepted.connect_info().remote_addr(),
        first.local_addr().ok()
    );
    first.write_all(b"request").await.expect("request");
    let mut data = [0; 7];
    accepted.read_exact(&mut data).await.expect("read");
    assert_eq!(&data, b"request");
    accepted.write_all(b"ok").await.expect("response");
    let mut response = [0; 2];
    first
        .read_exact(&mut response)
        .await
        .expect("response read");
    assert_eq!(&response, b"ok");
    let second = TcpStream::connect(address).await.expect("kernel backlog");
    pending(&mut incoming).await;
    drop(first);
    assert_eq!(accepted.read(&mut data).await.expect("EOF"), 0);
    pending(&mut incoming).await;
    assert_eq!(
        capacity.available_permits(),
        0,
        "peer loss is not socket destruction"
    );
    drop(accepted);
    let accepted_second = next(&mut incoming).await;
    assert_eq!(
        accepted_second.connect_info().remote_addr(),
        second.local_addr().ok()
    );
    drop(incoming);
    assert_eq!(
        capacity.available_permits(),
        0,
        "listener drop must not return live socket capacity"
    );
    drop(accepted_second);
    assert_eq!(capacity.available_permits(), 1);
}
