// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{Client, Endpoint, client_builder};
use crate::{Message, Options, Protocol, Request, Role, TurnEvent, TurnStream};
use bytes::Bytes;
use h2::{Reason, SendStream};
use std::{future::poll_fn, io, sync::Arc, time::Duration};
use tokio::{net::TcpListener, sync::oneshot, task::JoinSet, time::timeout};
use tokio_rustls::TlsAcceptor;

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

const WATCHDOG: Duration = Duration::from_secs(5);
const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;
const FRAMES: usize = 768;
const FRAME_TEXT: usize = 16 * 1024;
const FIRST: &[u8] = b"data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"first\"}}]}\n\n";
const TERMINAL: &[u8] =
    b"data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn http2_paused_stream_allows_sibling_progress_and_cancels_independently() -> Result {
    let (client, acceptor) = tls_fixture()?;
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let address = listener.local_addr()?;
    let (stalled_tx, stalled_rx) = oneshot::channel();
    let (finished_tx, mut finished_rx) = oneshot::channel();
    let (reset_tx, reset_rx) = oneshot::channel();
    let (stop_tx, stop_rx) = oneshot::channel();
    let server = tokio::spawn(serve_connection(
        listener,
        acceptor,
        (stalled_tx, finished_tx),
        reset_tx,
        stop_rx,
    ));

    let mut phase = "open slow response";
    let result = timeout(WATCHDOG, async {
        let mut slow = open_turn(&client, address, "/slow").await?;
        assert_eq!(
            slow.next_event().await?,
            Some(TurnEvent::Text("first".into()))
        );
        phase = "observe stalled producer";
        stalled_rx.await?;
        phase = "complete sibling response";
        check_fast_turn(&client, address).await?;
        assert_eq!(
            finished_rx.try_recv(),
            Err(oneshot::error::TryRecvError::Empty)
        );
        phase = "drain slow response";
        drain_slow_turn(&mut slow).await?;
        finished_rx.await?;

        phase = "open cancellable response";
        let mut cancelled = open_turn(&client, address, "/cancel").await?;
        assert_eq!(
            cancelled.next_event().await?,
            Some(TurnEvent::Text("first".into()))
        );
        drop(cancelled);
        phase = "observe cancellation reset";
        assert_eq!(reset_rx.await?, Reason::CANCEL);
        phase = "reuse connection after reset";
        check_fast_turn(&client, address).await?;

        phase = "stop fixture connection";
        stop_tx
            .send(())
            .map_err(|()| io::Error::other("missing HTTP/2 connection"))?;
        server.await??;
        Ok::<_, Box<dyn std::error::Error + Send + Sync>>(())
    })
    .await;
    result
        .unwrap_or_else(|error| Err(Box::new(error)))
        .map_err(|error| io::Error::other(format!("HTTP/2 {phase}: {error}")).into())
}

fn tls_fixture() -> Result<(Client, TlsAcceptor)> {
    let certificate = rcgen::generate_simple_self_signed(vec!["127.0.0.1".into()])?;
    let der = certificate.cert.der().clone();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der());
    let mut server = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .with_no_client_auth()
    .with_single_cert(vec![der.clone()], key.into())?;
    server.alpn_protocols = vec![b"h2".to_vec()];
    let http = client_builder(WATCHDOG)
        .tls_certs_only([reqwest::Certificate::from_der(der.as_ref())?])
        .http2_initial_stream_window_size(16 * 1024)
        .http2_initial_connection_window_size(128 * 1024)
        .build()?;
    Ok((
        Client {
            http,
            response_limit: RESPONSE_LIMIT,
        },
        TlsAcceptor::from(Arc::new(server)),
    ))
}

async fn open_turn(
    client: &Client,
    address: std::net::SocketAddr,
    path: &str,
) -> Result<TurnStream> {
    let endpoint = Endpoint::new(Protocol::OpenAi, &format!("https://{address}{path}"))?;
    let messages = [Message {
        role: Role::User,
        content: "fixture".into(),
        images: Vec::new(),
        name: None,
        tool_call_id: None,
        tool_calls: Vec::new(),
        responses_output: None,
    }];
    Ok(client
        .stream_turn(
            &endpoint,
            "snake-oil",
            &Request {
                model: "fixture",
                messages: &messages,
                options: &Options::default(),
            },
        )
        .await?)
}

async fn check_fast_turn(client: &Client, address: std::net::SocketAddr) -> Result {
    let mut turn = open_turn(client, address, "/fast").await?;
    assert_eq!(
        turn.next_event().await?,
        Some(TurnEvent::Text("first".into()))
    );
    assert!(matches!(
        turn.next_event().await?,
        Some(TurnEvent::Finished { .. })
    ));
    assert!(turn.next_event().await?.is_none());
    Ok(())
}

async fn drain_slow_turn(slow: &mut TurnStream) -> Result {
    for index in 0..FRAMES {
        let Some(TurnEvent::Text(text)) = slow.next_event().await? else {
            return Err(io::Error::other("missing HTTP/2 text frame").into());
        };
        assert_eq!(text.len(), FRAME_TEXT + 4);
        assert!(text.starts_with(&format!("{index:04}")));
    }
    assert!(matches!(
        slow.next_event().await?,
        Some(TurnEvent::Finished { .. })
    ));
    assert!(slow.next_event().await?.is_none());
    Ok(())
}

async fn serve_connection(
    listener: TcpListener,
    acceptor: TlsAcceptor,
    slow_signals: (oneshot::Sender<()>, oneshot::Sender<()>),
    reset: oneshot::Sender<Reason>,
    mut stop: oneshot::Receiver<()>,
) -> Result {
    let (socket, _) = listener.accept().await?;
    // Keep small flow-control writes from waiting on delayed TCP acknowledgements.
    socket.set_nodelay(true)?;
    let tls = acceptor.accept(socket).await?;
    assert_eq!(tls.get_ref().1.alpn_protocol(), Some(b"h2".as_slice()));
    let mut conn = h2::server::handshake(tls).await?;
    let mut responses = JoinSet::new();
    let mut slow_signals = Some(slow_signals);
    let mut reset = Some(reset);
    loop {
        let incoming = tokio::select! {
            incoming = conn.accept() => incoming,
            signal = &mut stop => { signal?; break; }
        };
        let (request, response) =
            incoming.ok_or_else(|| io::Error::other("HTTP/2 connection closed early"))??;
        assert_eq!(request.version(), http::Version::HTTP_2);
        let path = request.uri().path().to_owned();
        let slow_signals = (path == "/slow").then(|| slow_signals.take()).flatten();
        let reset = (path == "/cancel").then(|| reset.take()).flatten();
        responses.spawn(send_response(
            request.into_body(),
            response,
            slow_signals,
            reset,
        ));
    }
    while let Some(result) = responses.join_next().await {
        result??;
    }
    Ok(())
}

async fn send_response(
    mut request: h2::RecvStream,
    mut response: h2::server::SendResponse<Bytes>,
    slow_signals: Option<(oneshot::Sender<()>, oneshot::Sender<()>)>,
    reset: Option<oneshot::Sender<Reason>>,
) -> Result {
    while let Some(chunk) = request.data().await {
        request.flow_control().release_capacity(chunk?.len())?;
    }
    let headers = http::Response::builder()
        .header("content-type", "text/event-stream")
        .body(())?;
    let mut body = response.send_response(headers, false)?;
    body.send_data(Bytes::from_static(FIRST), false)?;
    if let Some(reset) = reset {
        let reason = poll_fn(|cx| body.poll_reset(cx)).await?;
        reset
            .send(reason)
            .map_err(|_| io::Error::other("missing reset observer"))?;
        return Ok(());
    }
    let finished = if let Some((stalled, finished)) = slow_signals {
        send_burst(&mut body, stalled).await?;
        Some(finished)
    } else {
        None
    };
    body.send_data(Bytes::from_static(TERMINAL), true)?;
    if let Some(finished) = finished {
        let _ = finished.send(());
    }
    Ok(())
}

async fn send_burst(body: &mut SendStream<Bytes>, stalled: oneshot::Sender<()>) -> Result {
    let padding = "x".repeat(FRAME_TEXT);
    let mut stalled = Some(stalled);
    for index in 0..FRAMES {
        let mut frame = Bytes::from(format!(
            "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{index:04}{padding}\"}}}}]}}\n\n"
        ));
        while !frame.is_empty() {
            let capacity = wait_capacity(body, frame.len(), &mut stalled).await?;
            let piece = frame.split_to(capacity.min(frame.len()));
            body.send_data(piece, false)?;
        }
    }
    Ok(())
}

async fn wait_capacity(
    body: &mut SendStream<Bytes>,
    remaining: usize,
    stalled: &mut Option<oneshot::Sender<()>>,
) -> Result<usize> {
    body.reserve_capacity(remaining);
    if body.capacity() > 0 {
        return Ok(body.capacity());
    }
    let ready = poll_fn(|cx| body.poll_capacity(cx));
    tokio::pin!(ready);
    if stalled.is_some() {
        match timeout(Duration::from_millis(100), &mut ready).await {
            Ok(capacity) => {
                return capacity
                    .ok_or_else(|| io::Error::other("closed stream"))?
                    .map_err(Into::into);
            }
            Err(_) => {
                if let Some(signal) = stalled.take() {
                    signal
                        .send(())
                        .map_err(|()| io::Error::other("missing backpressure observer"))?;
                }
            }
        }
    }
    Ok(ready
        .await
        .ok_or_else(|| io::Error::other("closed stream"))??)
}
