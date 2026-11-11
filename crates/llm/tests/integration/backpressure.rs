// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{TestResult, messages, read_request};
use std::{io, net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    net::{TcpListener, TcpSocket},
    sync::oneshot,
    time::timeout,
};
use tokio_stream::StreamExt;
use weaver_llm::{Client, Endpoint, Error, Options, Protocol, Request, TurnEvent};

const HEADER: &str =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n";
const FIRST: &str = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"first\"}}]}\n\n";
const TERMINAL: &str = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
const WATCHDOG: Duration = Duration::from_secs(5);

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn paused_consumer_stalls_upstream_and_resumes_in_order() -> TestResult {
    const FRAMES: usize = 768;
    const FRAME_TEXT: usize = 16 * 1024;
    let socket = TcpSocket::new_v4()?;
    socket.set_send_buffer_size(64 * 1024)?;
    socket.bind(SocketAddr::from(([127, 0, 0, 1], 0)))?;
    let listener = socket.listen(1)?;
    let address = listener.local_addr()?;
    let (resume_tx, resume_rx) = oneshot::channel();
    let (blocked_tx, blocked_rx) = oneshot::channel();
    let (finished_tx, mut finished_rx) = oneshot::channel();

    let mut upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await?;
        let mut socket = BufReader::new(socket);
        read_request(&mut socket).await?;
        let writer = socket.get_mut();
        writer.write_all(HEADER.as_bytes()).await?;
        writer.write_all(FIRST.as_bytes()).await?;
        resume_rx.await.map_err(io::Error::other)?;
        let mut blocked_tx = Some(blocked_tx);
        let padding = "x".repeat(FRAME_TEXT);
        for index in 0..FRAMES {
            let frame = format!(
                "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{index:04}{padding}\"}}}}]}}\n\n"
            );
            let mut remaining = frame.as_bytes();
            while !remaining.is_empty() {
                match writer.try_write(remaining) {
                    Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
                    Ok(count) => remaining = &remaining[count..],
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                        if let Some(blocked_tx) = blocked_tx.take() {
                            let _ = blocked_tx.send(());
                        }
                        writer.writable().await?;
                    }
                    Err(error) => return Err(error),
                }
            }
        }
        writer.write_all(TERMINAL.as_bytes()).await?;
        let _ = finished_tx.send(());
        Ok::<_, io::Error>(())
    });

    let client = Client::new(WATCHDOG, 16 * 1024 * 1024)?;
    let endpoint = Endpoint::new(Protocol::OpenAi, &format!("http://{address}/model"))?;
    let turn = client
        .stream_turn(
            &endpoint,
            "snake-oil",
            &Request {
                model: "fixture",
                messages: &messages(),
                options: &Options::default(),
            },
        )
        .await?;
    let mut events = std::pin::pin!(turn.into_stream());
    assert_eq!(
        events.next().await.transpose()?,
        Some(TurnEvent::Text("first".into()))
    );
    resume_tx
        .send(())
        .map_err(|()| io::Error::other("missing upstream"))?;
    timeout(WATCHDOG, blocked_rx).await??;

    // The socket has refused a write. The paused consumer must keep the
    // producer from finishing the full burst until it starts polling again.
    assert!(
        timeout(Duration::from_millis(120), &mut finished_rx)
            .await
            .is_err()
    );

    timeout(WATCHDOG, async {
        for index in 0..FRAMES {
            let Some(TurnEvent::Text(text)) = events.next().await.transpose()? else {
                return Err(io::Error::other("missing text frame").into());
            };
            assert_eq!(text.len(), FRAME_TEXT + 4);
            assert!(text.starts_with(&format!("{index:04}")));
        }
        assert!(matches!(
            events.next().await.transpose()?,
            Some(TurnEvent::Finished { .. })
        ));
        assert!(events.next().await.is_none());
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await??;
    timeout(WATCHDOG, finished_rx).await??;
    timeout(WATCHDOG, &mut upstream).await???;
    Ok(())
}

#[tokio::test]
async fn cancelling_one_poll_preserves_a_partially_read_frame() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let (suffix_tx, suffix_rx) = oneshot::channel();

    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await?;
        let mut socket = BufReader::new(socket);
        read_request(&mut socket).await?;
        let writer = socket.get_mut();
        writer.write_all(HEADER.as_bytes()).await?;
        writer
            .write_all(b"data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"split")
            .await?;
        suffix_rx.await.map_err(io::Error::other)?;
        writer.write_all(b" frame\"}}]}\n\n").await?;
        writer.write_all(TERMINAL.as_bytes()).await
    });

    let endpoint = Endpoint::new(Protocol::OpenAi, &format!("http://{address}/model"))?;
    let mut turn = Client::new(WATCHDOG, 4096)?
        .stream_turn(
            &endpoint,
            "snake-oil",
            &Request {
                model: "fixture",
                messages: &messages(),
                options: &Options::default(),
            },
        )
        .await?;
    assert!(
        timeout(Duration::from_millis(100), turn.next_event())
            .await
            .is_err()
    );
    suffix_tx
        .send(())
        .map_err(|()| io::Error::other("missing upstream"))?;
    assert_eq!(
        turn.next_event().await?,
        Some(TurnEvent::Text("split frame".into()))
    );
    assert!(matches!(
        turn.next_event().await?,
        Some(TurnEvent::Finished { .. })
    ));
    assert!(turn.next_event().await?.is_none());
    timeout(WATCHDOG, upstream).await???;
    Ok(())
}

#[tokio::test]
async fn cumulative_budget_rejects_individually_small_frames() -> TestResult {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let (continue_tx, continue_rx) = oneshot::channel();
    let upstream = tokio::spawn(async move {
        let (socket, _) = listener.accept().await?;
        let mut socket = BufReader::new(socket);
        read_request(&mut socket).await?;
        let writer = socket.get_mut();
        writer.write_all(HEADER.as_bytes()).await?;
        writer.write_all(FIRST.as_bytes()).await?;
        continue_rx.await.map_err(io::Error::other)?;
        writer.write_all(FIRST.as_bytes()).await?;
        writer.write_all(FIRST.as_bytes()).await
    });
    let endpoint = Endpoint::new(Protocol::OpenAi, &format!("http://{address}/model"))?;
    let mut turn = Client::new(WATCHDOG, FIRST.len() + FIRST.len() / 2)?
        .stream_turn(
            &endpoint,
            "snake-oil",
            &Request {
                model: "fixture",
                messages: &messages(),
                options: &Options::default(),
            },
        )
        .await?;
    assert_eq!(
        turn.next_event().await?,
        Some(TurnEvent::Text("first".into()))
    );
    continue_tx
        .send(())
        .map_err(|()| io::Error::other("missing upstream"))?;
    assert!(matches!(turn.next_event().await, Err(Error::Limit)));
    assert!(turn.next_event().await?.is_none());
    timeout(WATCHDOG, upstream).await???;
    Ok(())
}
