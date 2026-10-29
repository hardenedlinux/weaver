use super::{OpenStream, StreamSession};
use std::{io::Read, net::TcpListener, thread, time::Duration};
use weaver_contracts::{
    MessageRule, MessageState, StreamContract, StreamMessage, Task, WriteObservation, body_digest,
};
use weaver_ledger::Ledger;

const ALLOW: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../dev/policies/streaming/stream.cedar"
));

fn fixture(destination: String) -> (tempfile::TempDir, Ledger, StreamContract) {
    let temp = tempfile::tempdir().expect("temp");
    let mut ledger = Ledger::open(temp.path().join("stream.db")).expect("ledger");
    ledger.publish(None, ALLOW, 1).expect("publish");
    let input = body_digest("original-input");
    let mut task = Task {
        family: "f".into(),
        principal: "alice".into(),
        profile: "p".into(),
        nodes: vec!["emit".into()],
        targets: vec!["primary".into()],
        endpoints: [("primary".into(), "https://provider.invalid/".into())].into(),
        body_digests: [("emit".into(), input.clone())].into(),
        stream_contracts: Default::default(),
        node_cost_bounds: [("emit".into(), 20)].into(),
        models: vec!["m".into()],
        budget: 20,
    };
    let contract = StreamContract {
        family: "f".into(),
        node: "emit".into(),
        profile: "p".into(),
        target: "primary".into(),
        input_digest: input,
        destination,
        messages: vec![
            MessageRule {
                id: "m0".into(),
                max_bytes: 1_048_576,
                cost_bound: 4,
            },
            MessageRule {
                id: "m1".into(),
                max_bytes: 1_048_576,
                cost_bound: 4,
            },
        ],
    };
    task.stream_contracts
        .insert("emit".into(), contract.digest().expect("commit manifest"));
    ledger.register_task(&task).expect("task");
    ledger.register_stream(&contract).expect("manifest");
    (temp, ledger, contract)
}
fn queue(ledger: &mut Ledger, c: &StreamContract, id: &str, payload: String) {
    ledger
        .enqueue_message(&StreamMessage {
            family: "f".into(),
            node: "emit".into(),
            message: id.into(),
            contract_digest: c.digest().expect("digest"),
            payload,
            ceiling: 4,
            revision: 0,
            fence: 1,
        })
        .expect("queue");
}
fn open<'a>(c: &'a StreamContract, revision: u64, fence: u64) -> OpenStream<'a> {
    OpenStream {
        family: "f",
        node: "emit",
        destination: &c.destination,
        revision,
        fence,
    }
}
fn reader(listener: TcpListener) -> thread::JoinHandle<Vec<u8>> {
    thread::spawn(move || {
        let (mut socket, _) = listener.accept().expect("accept");
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("timeout");
        let mut bytes = Vec::new();
        socket.read_to_end(&mut bytes).expect("read");
        bytes
    })
}

#[test]
fn actual_tcp_ranges_preserve_one_message_and_one_hold() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let destination = format!("tcp://{}", listener.local_addr().expect("address"));
    let worker = reader(listener);
    let (_temp, mut ledger, c) = fixture(destination);
    queue(&mut ledger, &c, "m0", "abcdefgh".into());
    let mut session = StreamSession::open_tcp(&mut ledger, open(&c, 0, 1)).expect("open");
    assert_eq!(
        session.send_next(&mut ledger, "m0", 4).expect("first"),
        WriteObservation::Complete
    );
    assert_eq!(
        session.send_next(&mut ledger, "m0", 4).expect("tail"),
        WriteObservation::Complete
    );
    session.close();
    assert_eq!(worker.join().expect("join"), b"abcdefgh");
    assert_eq!(
        ledger
            .message_receipt("f", "emit", "m0")
            .expect("lookup")
            .expect("receipt")
            .state,
        MessageState::Complete
    );
    assert_eq!(ledger.held("f").expect("held"), 4);
}

#[test]
fn effective_revocation_stops_actual_next_range_and_prefix_reconnect() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let destination = format!("tcp://{}", listener.local_addr().expect("address"));
    let worker = reader(listener);
    let (_temp, mut ledger, c) = fixture(destination);
    queue(&mut ledger, &c, "m0", "abcdefgh".into());
    let mut session = StreamSession::open_tcp(&mut ledger, open(&c, 0, 1)).expect("open");
    session.send_next(&mut ledger, "m0", 4).expect("first");
    ledger
        .publish(Some(0), "forbid(principal,action,resource);", 2)
        .expect("revoke");
    assert!(session.send_next(&mut ledger, "m0", 4).is_err());
    assert_eq!(worker.join().expect("join"), b"abcd");
    ledger.publish(Some(1), ALLOW, 3).expect("allow again");
    assert!(StreamSession::open_tcp(&mut ledger, open(&c, 2, 3)).is_err());
    assert_eq!(ledger.held("f").expect("held"), 4);
}

#[test]
fn revoke_after_range_consumption_proves_zero_call_and_recovers_original_message() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let destination = format!("tcp://{}", listener.local_addr().expect("address"));
    let worker = thread::spawn(move || {
        let mut received = Vec::new();
        for _ in 0..2 {
            let (mut s, _) = listener.accept().expect("accept");
            s.set_read_timeout(Some(Duration::from_secs(3)))
                .expect("timeout");
            s.read_to_end(&mut received).expect("read");
        }
        received
    });
    let (_temp, mut ledger, c) = fixture(destination);
    queue(&mut ledger, &c, "m0", "abcdefgh".into());
    let original = ledger
        .message_receipt("f", "emit", "m0")
        .expect("lookup")
        .expect("receipt")
        .digest;
    let mut old = StreamSession::open_tcp(&mut ledger, open(&c, 0, 1)).expect("open");
    let permit = ledger.consume_range(&old.owner, "m0", 8).expect("burn");
    ledger.publish(Some(0), "", 2).expect("revoke");
    let mut calls = 0;
    assert!(
        ledger
            .write_range(&old.owner, permit, |bytes| {
                calls += 1;
                old.sink.as_mut().expect("sink").write_once(bytes)
            })
            .is_err()
    );
    assert_eq!(calls, 0);
    old.close();
    ledger.publish(Some(1), ALLOW, 3).expect("allow again");
    let mut new = StreamSession::open_tcp(&mut ledger, open(&c, 2, 3)).expect("new owner");
    new.resume_message(&mut ledger, "m0", 2, 3)
        .expect("reauthorize original");
    new.send_next(&mut ledger, "m0", 8).expect("send");
    new.close();
    assert_eq!(worker.join().expect("join"), b"abcdefgh");
    assert_eq!(
        ledger
            .message_receipt("f", "emit", "m0")
            .expect("lookup")
            .expect("receipt")
            .digest,
        original
    );
    assert_eq!(ledger.held("f").expect("held"), 4);
}

#[test]
fn native_partial_write_freezes_tail_and_never_refunds() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let destination = format!("tcp://{}", listener.local_addr().expect("address"));
    socket2::SockRef::from(&listener)
        .set_recv_buffer_size(1024)
        .expect("listener window");
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let worker = thread::spawn(move || {
        let (mut socket, _) = listener.accept().expect("accept");
        socket2::SockRef::from(&socket)
            .set_recv_buffer_size(1024)
            .expect("receive buffer");
        let _ = release_rx.recv_timeout(Duration::from_secs(5));
        let mut bytes = Vec::new();
        socket
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("timeout");
        let _ = socket.read_to_end(&mut bytes);
        bytes
    });
    let (_temp, mut ledger, c) = fixture(destination);
    queue(&mut ledger, &c, "m0", "x".repeat(1_048_576));
    let mut session = StreamSession::open_tcp(&mut ledger, open(&c, 0, 1)).expect("open");
    socket2::SockRef::from(&session.sink.as_mut().expect("sink").socket().stream)
        .set_send_buffer_size(1024)
        .expect("send buffer");
    let observation = session
        .send_next(&mut ledger, "m0", 1_048_576)
        .expect("native write result");
    release_tx
        .send(())
        .expect("release receiver after native result");
    assert_ne!(observation, WriteObservation::Complete);
    let bytes = worker.join().expect("join");
    assert!(!bytes.is_empty() && bytes.len() < 1_048_576);
    assert!(session.send_next(&mut ledger, "m0", 1).is_err());
    assert!(StreamSession::open_tcp(&mut ledger, open(&c, 0, 1)).is_err());
    assert_eq!(
        ledger
            .message_receipt("f", "emit", "m0")
            .expect("lookup")
            .expect("receipt")
            .state,
        MessageState::Unknown
    );
    assert_eq!(ledger.held("f").expect("held"), 4);
}

#[test]
fn recovered_old_worker_socket_cannot_use_new_custody() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let destination = format!("tcp://{}", listener.local_addr().expect("address"));
    let worker = thread::spawn(move || {
        let mut all = Vec::new();
        for _ in 0..2 {
            let (mut s, _) = listener.accept().expect("accept");
            s.set_read_timeout(Some(Duration::from_secs(3)))
                .expect("timeout");
            s.read_to_end(&mut all).expect("read");
        }
        all
    });
    let (_temp, mut ledger, c) = fixture(destination);
    queue(&mut ledger, &c, "m0", "abcdefgh".into());
    let mut old = StreamSession::open_tcp(&mut ledger, open(&c, 0, 1)).expect("old");
    let mut current = StreamSession::open_tcp(&mut ledger, open(&c, 0, 1)).expect("handoff");
    assert!(old.send_next(&mut ledger, "m0", 8).is_err());
    current
        .send_next(&mut ledger, "m0", 8)
        .expect("current write");
    current.close();
    assert_eq!(worker.join().expect("join"), b"abcdefgh");
    assert_eq!(ledger.held("f").expect("held"), 4);
}

#[test]
fn tls_flush_cannot_release_a_tail_after_effective_revocation() {
    use std::{io::Read, sync::Arc};
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let address = listener.local_addr().expect("address");
    let certified =
        rcgen::generate_simple_self_signed(vec!["localhost".into()]).expect("certificate");
    let cert = certified.cert.der().clone();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(certified.signing_key.serialize_der());
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("protocols")
    .with_no_client_auth()
    .with_single_cert(vec![cert.clone()], key.into())
    .expect("config");
    let worker = thread::spawn(move || {
        let (socket, _) = listener.accept().expect("accept");
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("deadline");
        let mut tls = rustls::StreamOwned::new(
            rustls::ServerConnection::new(Arc::new(config)).expect("server"),
            socket,
        );
        let mut all = Vec::new();
        let mut buffer = [0u8; 256];
        loop {
            match tls.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(n) => all.extend_from_slice(&buffer[..n]),
            }
        }
        all
    });
    let (_temp, mut ledger, c) = fixture(format!("tls://localhost:{}", address.port()));
    queue(&mut ledger, &c, "m0", "abcdefgh".into());
    let mut session = StreamSession::open_tls(
        &mut ledger,
        open(&c, 0, 1),
        crate::StreamTlsConfig {
            address,
            root_certificates: vec![cert.to_vec()],
        },
    )
    .expect("verified TLS");
    session
        .send_next(&mut ledger, "m0", 4)
        .expect("first TLS range");
    ledger.publish(Some(0), "", 2).expect("revoke");
    assert!(session.send_next(&mut ledger, "m0", 4).is_err());
    assert_eq!(worker.join().expect("join"), b"abcd");
    assert_eq!(ledger.held("f").expect("held"), 4);
}
