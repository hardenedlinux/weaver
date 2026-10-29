use sha2::{Digest, Sha256};
use std::{io::Read, thread};
use weaver_contracts::{MessageRule, StreamContract, StreamMessage, Task, body_digest};
use weaver_ledger::Ledger;
const TOKEN: &str = "development-owner-token";
const POLICY: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../dev/policies/streaming/stream.cedar"
));

async fn fixture(
    principal: &str,
    destination: String,
) -> (
    tempfile::TempDir,
    String,
    StreamMessage,
    tokio::task::JoinHandle<weaver_contracts::Result<()>>,
    tokio::sync::oneshot::Sender<()>,
) {
    let temp = tempfile::tempdir().expect("temp");
    let database = temp.path().join("server.db");
    let mut ledger = Ledger::open(&database).expect("db");
    ledger.publish(None, POLICY, 1).expect("publish");
    let c = StreamContract {
        family: "f".into(),
        node: "emit".into(),
        profile: "p".into(),
        target: "t".into(),
        input_digest: body_digest("input"),
        destination,
        messages: vec![MessageRule {
            id: "m0".into(),
            max_bytes: 8,
            cost_bound: 4,
        }],
    };
    ledger
        .register_task(&Task {
            family: "f".into(),
            principal: "alice".into(),
            profile: "p".into(),
            nodes: vec!["emit".into()],
            targets: vec!["t".into()],
            endpoints: [("t".into(), "https://provider.invalid/".into())].into(),
            body_digests: [("emit".into(), c.input_digest.clone())].into(),
            node_cost_bounds: [("emit".into(), 4)].into(),
            stream_contracts: [("emit".into(), c.digest().expect("contract"))].into(),
            models: vec!["m".into()],
            budget: 4,
        })
        .expect("task");
    ledger.register_stream(&c).expect("stream");
    let (url, server, shutdown) = launch(principal, database).await;
    let message = StreamMessage {
        family: "f".into(),
        node: "emit".into(),
        message: "m0".into(),
        contract_digest: c.digest().expect("digest"),
        payload: "abcdef".into(),
        ceiling: 4,
        revision: 0,
        fence: 1,
    };
    (temp, url, message, server, shutdown)
}
async fn launch(
    principal: &str,
    database: std::path::PathBuf,
) -> (
    String,
    tokio::task::JoinHandle<weaver_contracts::Result<()>>,
    tokio::sync::oneshot::Sender<()>,
) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind");
    let address = listener.local_addr().expect("address");
    let config = weaver_server::ServerConfig {
        database,
        principal: principal.into(),
        token_sha256: Sha256::digest(TOKEN.as_bytes()).into(),
        max_in_flight: 2,
    };
    let (shutdown, stopped) = tokio::sync::oneshot::channel();
    let server = tokio::spawn(weaver_server::serve_with_shutdown(
        listener,
        config,
        async {
            let _ = stopped.await;
        },
    ));
    (format!("http://{address}"), server, shutdown)
}
async fn post(
    client: &reqwest::Client,
    url: &str,
    token: &str,
    body: &serde_json::Value,
) -> reqwest::Response {
    client
        .post(url)
        .bearer_auth(token)
        .header("Content-Type", "application/json")
        .body(serde_json::to_vec(body).expect("body"))
        .send()
        .await
        .expect("response")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn authenticated_api_preserves_identity_and_final_range_effects() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("sink");
    let destination = format!("tcp://{}", listener.local_addr().expect("addr"));
    let worker = thread::spawn(move || {
        let (mut socket, _) = listener.accept().expect("accept");
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
            .expect("timeout");
        let mut bytes = Vec::new();
        socket.read_to_end(&mut bytes).expect("read");
        bytes
    });
    let (temp, url, message, server, shutdown) = fixture("alice", destination).await;
    let client = reqwest::Client::new();
    let body = serde_json::to_value(message).expect("message");
    assert_eq!(
        post(&client, &format!("{url}/v1/messages"), "wrong-token", &body)
            .await
            .status(),
        401
    );
    assert_eq!(
        Ledger::open(temp.path().join("server.db"))
            .expect("db")
            .held("f")
            .expect("held"),
        0
    );
    assert!(
        post(&client, &format!("{url}/v1/messages"), TOKEN, &body)
            .await
            .status()
            .is_success()
    );
    let send = serde_json::json!({"revision":0,"fence":1,"max_range":3});
    assert!(
        post(
            &client,
            &format!("{url}/v1/messages/f/emit/m0/send"),
            TOKEN,
            &send
        )
        .await
        .status()
        .is_success()
    );
    assert_eq!(worker.join().expect("sink"), b"abcdef");
    assert!(
        post(
            &client,
            &format!("{url}/v1/messages/f/emit/m0/send"),
            TOKEN,
            &send
        )
        .await
        .status()
        .is_success()
    );
    assert_eq!(
        Ledger::open(temp.path().join("server.db"))
            .expect("db")
            .held("f")
            .expect("held"),
        4
    );
    shutdown.send(()).expect("shutdown");
    tokio::time::timeout(std::time::Duration::from_secs(3), server)
        .await
        .expect("stop deadline")
        .expect("server task")
        .expect("clean stop");
    // The old sink is gone. Success after restart must be a durable receipt, never a reconnect.
    let (url, server, shutdown) = launch("alice", temp.path().join("server.db")).await;
    let response = post(
        &client,
        &format!("{url}/v1/messages/f/emit/m0/send"),
        TOKEN,
        &send,
    )
    .await;
    assert!(response.status().is_success());
    let bytes = response.bytes().await.expect("receipt bytes");
    let receipt: weaver_contracts::MessageReceipt =
        serde_json::from_slice(&bytes).expect("receipt");
    assert_eq!(receipt.state, weaver_contracts::MessageState::Complete);
    assert_eq!(
        Ledger::open(temp.path().join("server.db"))
            .expect("db")
            .held("f")
            .expect("held"),
        4
    );
    shutdown.send(()).expect("restart shutdown");
    tokio::time::timeout(std::time::Duration::from_secs(3), server)
        .await
        .expect("stop deadline")
        .expect("server task")
        .expect("clean stop");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn valid_transport_credential_cannot_impersonate_original_task_owner() {
    let (temp, url, message, server, shutdown) = fixture("bob", "tcp://127.0.0.1:1".into()).await;
    let client = reqwest::Client::new();
    assert_eq!(
        post(
            &client,
            &format!("{url}/v1/messages"),
            TOKEN,
            &serde_json::to_value(message).expect("body")
        )
        .await
        .status(),
        403
    );
    assert_eq!(
        Ledger::open(temp.path().join("server.db"))
            .expect("db")
            .held("f")
            .expect("held"),
        0
    );
    shutdown.send(()).expect("shutdown");
    tokio::time::timeout(std::time::Duration::from_secs(3), server)
        .await
        .expect("stop deadline")
        .expect("server task")
        .expect("clean stop");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn current_revocation_prevents_server_from_opening_an_egress_connection() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("sink");
    listener.set_nonblocking(true).expect("nonblocking");
    let (temp, url, message, server, shutdown) = fixture(
        "alice",
        format!("tcp://{}", listener.local_addr().expect("addr")),
    )
    .await;
    let client = reqwest::Client::new();
    assert!(
        post(
            &client,
            &format!("{url}/v1/messages"),
            TOKEN,
            &serde_json::to_value(message).expect("body")
        )
        .await
        .status()
        .is_success()
    );
    let mut ledger = Ledger::open(temp.path().join("server.db")).expect("db");
    ledger.publish(Some(0), "", 2).expect("revoke");
    let send = serde_json::json!({"revision":1,"fence":2,"max_range":3});
    assert_eq!(
        post(
            &client,
            &format!("{url}/v1/messages/f/emit/m0/send"),
            TOKEN,
            &send
        )
        .await
        .status(),
        403
    );
    assert!(listener.accept().is_err());
    assert_eq!(ledger.held("f").expect("held"), 4);
    shutdown.send(()).expect("shutdown");
    tokio::time::timeout(std::time::Duration::from_secs(3), server)
        .await
        .expect("stop deadline")
        .expect("server task")
        .expect("clean stop");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn incomplete_request_body_cannot_block_graceful_shutdown() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (temp, url, _, server, shutdown) = fixture("alice", "tcp://127.0.0.1:1".into()).await;
    let mut socket = tokio::net::TcpStream::connect(url.trim_start_matches("http://"))
        .await
        .expect("raw connection");
    socket.write_all(format!("POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n{{").as_bytes())
        .await.expect("incomplete body");
    // Force observation of an admitted body reader through the real HTTP path.
    // Two readers fill this fixture's slots; neither has submitted a native job.
    let mut second = tokio::net::TcpStream::connect(url.trim_start_matches("http://"))
        .await
        .expect("second connection");
    second.write_all(format!("POST /v1/messages HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n{{").as_bytes())
        .await.expect("second incomplete body");
    let client = reqwest::Client::new();
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        loop {
            let response = client
                .get(format!("{url}/v1/messages/f/emit/m0"))
                .bearer_auth(TOKEN)
                .send()
                .await
                .expect("probe");
            if response.status() == 503 {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("body readers admitted");
    shutdown.send(()).expect("shutdown");
    let mut response = Vec::new();
    tokio::time::timeout(
        std::time::Duration::from_secs(3),
        socket.read_to_end(&mut response),
    )
    .await
    .expect("reader stop deadline")
    .expect("reader closed");
    assert!(response.starts_with(b"HTTP/1.1 503"));
    drop(second);
    tokio::time::timeout(std::time::Duration::from_secs(3), server)
        .await
        .expect("stop deadline")
        .expect("server task")
        .expect("clean stop");
    assert_eq!(
        Ledger::open(temp.path().join("server.db"))
            .expect("db")
            .held("f")
            .expect("held"),
        0
    );
}
