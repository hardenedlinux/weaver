// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Independent HTTP/2 credit controls against the real HTTP/native output path.
use super::{Harness, fixture, protocol::Case};
use bytes::Bytes;
use std::{fmt::Write, time::Duration};
use tonic::codegen::http;
use weaver_telemetry::Signal;

const CHUNKS: usize = 64;
const WIDTH: usize = 32_768;
#[derive(Clone, Copy, Debug)]
enum Action {
    Consume,
    Stall,
    Reset,
    Withdraw,
}

fn reply() -> String {
    let text = "x".repeat(WIDTH);
    let mut wire = String::new();
    for _ in 0..CHUNKS {
        writeln!(wire,"data: {{\"id\":\"flow\",\"model\":\"model-a\",\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{text}\"}},\"finish_reason\":null}}]}}\n").expect("wire fixture");
    }
    wire.push_str(concat!(
        "data: {\"id\":\"flow\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
        "data: {\"id\":\"flow\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\n",
        "data: [DONE]\n\n"));
    wire
}
async fn request(
    client: &h2::client::SendRequest<Bytes>,
    request: http::Request<()>,
    body: Bytes,
) -> (http::Response<h2::RecvStream>, h2::SendStream<Bytes>) {
    let mut ready = client
        .clone()
        .ready()
        .await
        .expect("connection request capacity");
    let (response, mut sending) = ready
        .send_request(request, body.is_empty())
        .expect("H2 request");
    if !body.is_empty() {
        sending.send_data(body, true).expect("bounded request body");
    }
    (
        tokio::time::timeout(Duration::from_secs(3), response)
            .await
            .expect("response headers bound")
            .expect("response headers"),
        sending,
    )
}
async fn wire(mut body: h2::RecvStream) -> (Vec<u8>, bool) {
    tokio::time::timeout(Duration::from_secs(3), async move {
        let mut bytes = Vec::new();
        while let Some(data) = body.data().await {
            let data = match data {
                Ok(data) => data,
                Err(_) => return (bytes, false),
            };
            assert!(
                bytes.len() + data.len() <= 4 * 1024 * 1024,
                "bounded HTTP output"
            );
            body.flow_control()
                .release_capacity(data.len())
                .expect("explicit transport credit");
            bytes.extend_from_slice(&data);
        }
        (bytes, true)
    })
    .await
    .expect("bounded body progress")
}
async fn observed(owner: &Harness, signal: Signal, minimum: u64) {
    tokio::time::timeout(Duration::from_secs(3), async {
        let mut interval = tokio::time::interval(Duration::from_millis(5));
        loop {
            if owner.runtime.telemetry().snapshot().count(signal) >= minimum {
                break;
            }
            interval.tick().await;
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "bounded native observation: signal={signal:?} minimum={minimum} snapshot={:?}",
            owner.runtime.telemetry().snapshot()
        )
    });
}
fn text_and_terminals(wire: &[u8]) -> (usize, usize) {
    let mut decoder = weaver_llm::TurnDecoder::new(weaver_llm::Protocol::OpenAi, 4 * 1024 * 1024);
    decoder.push_bytes(wire).expect("bounded returned prefix");
    let mut text = 0;
    let mut terminal = 0;
    while let Some(event) = decoder.next_event().expect("valid returned event") {
        match event {
            weaver_llm::TurnEvent::Text(value) => {
                assert!(value.bytes().all(|byte| byte == b'x'));
                text += value.len();
            }
            weaver_llm::TurnEvent::Finished { .. } => terminal += 1,
            _ => panic!("no thinking or tool fixture"),
        }
    }
    (text, terminal)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn http2_window_reset_and_withdrawal_preserve_delivery_custody() {
    for action in [
        Action::Consume,
        Action::Stall,
        Action::Reset,
        Action::Withdraw,
    ] {
        let directory = tempfile::tempdir().expect("store");
        let database = directory.path().join("flow.db");
        let mut peer = fixture::provider(vec![reply()]).await;
        let owner = Harness::start(
            &database,
            &peer.root,
            Some((&peer.endpoint, weaver_contracts::CHAT_TURN_SSE)),
        )
        .await;
        let socket = tokio::net::TcpStream::connect(
            owner.base.strip_prefix("http://").expect("loopback HTTP"),
        )
        .await
        .expect("one client connection");
        socket.set_nodelay(true).expect("client transport");
        let (client, connection) = h2::client::Builder::new()
            .initial_window_size(1024)
            .initial_connection_window_size(65_536)
            .handshake::<_, Bytes>(socket)
            .await
            .expect("HTTP/2 connection");
        let pump = tokio::spawn(connection);
        let submitted = Case::Chat.first_request();
        let proposal = http::Request::builder()
            .method("POST")
            .uri(format!("{}/v1/chat/completions", owner.base))
            .header("authorization", "Bearer http-client-secret")
            .header("content-type", "application/json")
            .header("idempotency-key", "large-turn")
            .body(())
            .expect("request");
        let (response, mut sender) =
            request(&client, proposal, Bytes::from(submitted.clone())).await;
        assert_eq!(response.status(), 200, "{action:?}");
        let body = response.into_body();
        if !matches!(action, Action::Consume) {
            // No data() or release_capacity() call has occurred on this stream.
            observed(&owner, Signal::ResponseFramesQueued, 3).await;
            let query = http::Request::builder()
                .uri(format!("{}/v1/models", owner.base))
                .header("authorization", "Bearer http-client-secret")
                .body(())
                .expect("sibling query");
            let (models, _) = request(&client, query, Bytes::new()).await;
            assert_eq!(
                models.status(),
                200,
                "sibling is not blocked by the unread stream"
            );
            let (models, complete) = wire(models.into_body()).await;
            assert!(complete);
            let models: serde_json::Value = serde_json::from_slice(&models).expect("real catalog");
            assert_eq!(models["data"][0]["id"], "model-a");
            match action {
                Action::Reset => sender.send_reset(h2::Reason::CANCEL),
                Action::Withdraw => fixture::change(&owner.source, false).await,
                _ => {}
            }
            observed(&owner, Signal::ProviderFailed, 1).await;
        }
        let (bytes, complete) = wire(body).await;
        let (text, terminal) = text_and_terminals(&bytes);
        let healthy = matches!(action, Action::Consume);
        if healthy {
            assert!(complete);
            assert_eq!((text, terminal), (CHUNKS * WIDTH, 1));
            observed(&owner, Signal::ProviderCompleted, 1).await;
        } else {
            assert!(
                !complete,
                "{action:?}: aborted transport cannot claim successful EOF"
            );
            assert_eq!(terminal, 0);
            assert!(text < CHUNKS * WIDTH);
        }
        assert_eq!(
            peer.requests
                .recv()
                .await
                .expect("one actual provider request"),
            submitted
        );
        let query = http::Request::builder()
            .uri(format!("{}/v1/models", owner.base))
            .header("authorization", "Bearer http-client-secret")
            .body(())
            .expect("post-stream sibling query");
        let (models, _) = request(&client, query, Bytes::new()).await;
        assert_eq!(
            models.status(),
            if matches!(action, Action::Withdraw) {
                409
            } else {
                200
            },
            "{action:?}: a stream outcome cannot kill the shared connection"
        );
        let (_, complete) = wire(models.into_body()).await;
        assert!(complete);
        drop(sender);
        drop(client);
        owner.finish().await;
        let peer_result = peer
            .finish()
            .await
            .expect("no extra provider connection or fixture panic");
        if healthy {
            peer_result.expect("whole healthy provider reply");
        } else if let Err(error) = peer_result {
            assert!(
                matches!(
                    error.kind(),
                    std::io::ErrorKind::BrokenPipe
                        | std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::ConnectionAborted
                        | std::io::ErrorKind::UnexpectedEof
                ),
                "unexpected peer failure: {error}"
            );
        }
        let _ = tokio::time::timeout(Duration::from_secs(3), pump)
            .await
            .expect("connection drain bound")
            .expect("connection owner");
        let store = weaver_ledger::persistence::Session::open(&database).expect("native state");
        let (state, next): (String, i64) = weaver_ledger::persistence::one(
            &store,
            "SELECT state,next_event FROM provider_runs",
            (),
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .expect("durable execution outcome");
        let terminal: i64 = weaver_ledger::persistence::one(
            &store,
            "SELECT COUNT(*) FROM provider_terminal_usage",
            (),
            |row| row.get(0),
        )
        .expect("terminal usage outcome");
        assert_eq!(
            state,
            if healthy { "complete" } else { "unknown" },
            "{action:?}"
        );
        assert_eq!(terminal, i64::from(healthy));
        if !healthy {
            let held: i64 = weaver_ledger::persistence::one(
                &store,
                "SELECT held FROM budget_domains WHERE id=root",
                (),
                |row| row.get(0),
            )
            .expect("original hold");
            assert_eq!(
                held, 4,
                "{action:?}: no refund from cancellation or unknown delivery"
            );
            assert!(
                next < (CHUNKS + 2) as i64,
                "native owner cannot eagerly complete a paused response"
            );
        }
        store.close().expect("store exit");
    }
}
