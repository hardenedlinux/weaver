// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{ProviderOutput, ProviderTransport, open_guarded};
use crate::provider::test_runtime as fixture_runtime;
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{Read, Write},
    net::TcpListener,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
use weaver_contracts::{ProviderEvent, ProviderRoute, Result};
use weaver_ledger::Ledger;
#[path = "../../../contracts/benches/support/fixtures.rs"]
mod fixtures;
const SCHEMA: &str = include_str!("../../../../prod/policies/provider/schema.json");

struct Endpoint {
    runtime: tokio::runtime::Runtime,
    peer_closed: Arc<AtomicBool>,
    address: String,
    root: String,
    calls: Arc<AtomicUsize>,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Endpoint {
    fn new() -> Self {
        Self::with_header_delay(Duration::ZERO)
    }
    fn with_header_delay(delay: Duration) -> Self {
        Self::with_read_mode(delay, false)
    }
    fn with_read_mode(delay: Duration, wait_for_close: bool) -> Self {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        listener.set_nonblocking(true).expect("nonblocking");
        let address = format!(
            "https://localhost:{}/v1/chat/completions",
            listener.local_addr().expect("address").port()
        );
        let cert =
            rcgen::generate_simple_self_signed(vec!["localhost".into()]).expect("certificate");
        let root = cert.cert.pem();
        let key = rustls::pki_types::PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der());
        let config = Arc::new(
            rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .expect("protocols")
            .with_no_client_auth()
            .with_single_cert(vec![cert.cert.der().clone()], key.into())
            .expect("TLS"),
        );
        let calls = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let seen = calls.clone();
        let peer_closed = Arc::new(AtomicBool::new(false));
        let observed_close = peer_closed.clone();
        let closing = stop.clone();
        let worker = thread::spawn(move || {
            let start = Instant::now();
            while !closing.load(Ordering::SeqCst) && start.elapsed() < Duration::from_secs(2) {
                match listener.accept() {
                    Ok((socket, _)) => {
                        seen.fetch_add(1, Ordering::SeqCst);
                        socket
                            .set_nonblocking(false)
                            .expect("accepted blocking mode");
                        socket
                            .set_read_timeout(Some(Duration::from_secs(1)))
                            .expect("read bound");
                        socket
                            .set_write_timeout(Some(Duration::from_secs(1)))
                            .expect("write bound");
                        let connection =
                            rustls::ServerConnection::new(config.clone()).expect("server");
                        let mut stream = rustls::StreamOwned::new(connection, socket);
                        let mut bytes = [0; 4096];
                        assert!(stream.read(&mut bytes).expect("request") > 0);
                        if wait_for_close {
                            loop {
                                match stream.read(&mut bytes) {
                                    Ok(0) => {
                                        observed_close.store(true, Ordering::SeqCst);
                                        break;
                                    }
                                    Ok(_) => {}
                                    Err(error) => {
                                        observed_close.store(
                                            matches!(
                                                error.kind(),
                                                std::io::ErrorKind::UnexpectedEof
                                                    | std::io::ErrorKind::ConnectionReset
                                            ),
                                            Ordering::SeqCst,
                                        );
                                        break;
                                    }
                                }
                            }
                            continue;
                        }
                        thread::sleep(delay);

                        stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: 14\r\nConnection: close\r\n\r\ndata: [DONE]\n\n").expect("response");
                        stream.flush().expect("flush");
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(1))
                    }
                    Err(error) => panic!("accept: {error}"),
                }
            }
        });
        Self {
            runtime: fixture_runtime::fixture_runtime(),
            peer_closed,
            address,
            root,
            calls,
            stop,
            thread: Some(worker),
        }
    }
}
impl Drop for Endpoint {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.thread.take() {
            let joined = worker.join();
            if !thread::panicking() {
                joined.expect("endpoint joined");
            }
        }
    }
}
struct Cancellation {
    stopped: Arc<AtomicBool>,
    checkpoint: Mutex<Option<mpsc::Sender<()>>>,
}
impl ProviderOutput for Cancellation {
    type Slot = ();
    type PreparedFrame = ();
    fn stopped(&self) -> bool {
        let stopped = self.stopped.load(Ordering::SeqCst);
        if let Some(entered) = self.checkpoint.lock().expect("checkpoint").take() {
            let _ = entered.send(());
        }
        stopped
    }
    fn reserve(&mut self) -> Result<()> {
        panic!("no response release expected")
    }
    fn prepare(_: &ProviderRoute, _: &str, _: &[ProviderEvent], _: &str) -> Result<()> {
        panic!("no response preparation expected")
    }
    fn emit(&mut self, _: (), _: ()) -> Result<()> {
        panic!("no response release expected")
    }
}
struct LockedWriter {
    release: Option<mpsc::Sender<()>>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Drop for LockedWriter {
    fn drop(&mut self) {
        if let Some(release) = self.release.take() {
            let _ = release.send(());
        }
        if let Some(writer) = self.thread.take() {
            let joined = writer.join();
            if !thread::panicking() {
                joined.expect("writer joined");
            }
        }
    }
}
#[test]
fn cancellation_during_sql_wait_blocks_transport_and_keeps_spent_claim() {
    let endpoint = Endpoint::new();
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("ledger.db");
    let mut target = Ledger::open(&path).expect("target");
    target
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("policy");
    let (mut task, plan) = fixtures::task_plan(16, &endpoint.address);
    let mut blocker = plan.clone();
    blocker.node = "blocker".into();
    task.nodes.push(blocker.node.clone());
    task.body_digests.insert(
        blocker.node.clone(),
        weaver_contracts::body_digest(&blocker.body),
    );
    task.node_cost_bounds.insert(blocker.node.clone(), 4);
    task.stream_contracts
        .insert(blocker.node.clone(), blocker.digest().expect("commitment"));
    target.register_task(&task).expect("task");
    target.enqueue_provider(&plan).expect("target queue");
    let eligible = BTreeSet::from(["primary".into()]);
    let permit = target
        .consume_provider("f", "infer", &eligible)
        .expect("target consumed");
    let mut writer = Ledger::open(&path).expect("writer");
    writer.enqueue_provider(&blocker).expect("blocker queue");
    let blocked = writer
        .consume_provider("f", "blocker", &eligible)
        .expect("blocker consumed");
    let (entered, locked) = mpsc::channel();
    let (release, unlock) = mpsc::channel();
    let writing = thread::spawn(move || {
        writer
            .dispatch_provider(&blocked, || {
                entered.send(()).expect("locked");
                unlock.recv_timeout(Duration::from_secs(3)).expect("unlock");
                Ok(())
            })
            .expect("writer guard")
    });
    let mut lock = LockedWriter {
        release: Some(release),
        thread: Some(writing),
    };
    locked
        .recv_timeout(Duration::from_secs(3))
        .expect("write lock entered");
    let stopped = Arc::new(AtomicBool::new(false));
    let (before, waiting) = mpsc::channel();
    let output = Cancellation {
        stopped: stopped.clone(),
        checkpoint: Mutex::new(Some(before)),
    };
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "test-key".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("transport");
    let sending = thread::spawn(move || {
        let result = open_guarded(&mut target, &permit, &transport, &output);
        (target, permit, result.is_err())
    });
    waiting
        .recv_timeout(Duration::from_secs(3))
        .expect("pre-lock cancellation read");
    stopped.store(true, Ordering::SeqCst);
    lock.release
        .take()
        .expect("release")
        .send(())
        .expect("unlock");
    drop(lock);
    let (mut target, permit, denied) = sending.join().expect("sender joined");
    assert!(denied, "cancelled invocation entered HTTPS transport");
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 0);
    let running = Cancellation {
        stopped: Arc::new(AtomicBool::new(false)),
        checkpoint: Mutex::new(None),
    };
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "test-key".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("transport");
    assert!(
        open_guarded(&mut target, &permit, &transport, &running).is_err(),
        "new cancellation context reopened a burned dispatch"
    );
    drop(target);
    let recovered = Ledger::open(path).expect("recover");
    let receipt = recovered
        .provider_receipt("f", "infer")
        .expect("lookup")
        .expect("receipt");
    assert_eq!(receipt.state, weaver_contracts::ProviderState::Unknown);
    assert_eq!(receipt.held, 8);
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 0);
}

#[test]
fn uncancelled_control_reaches_real_https_transport_once() {
    let endpoint = Endpoint::new();
    let directory = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(directory.path().join("ledger.db")).expect("ledger");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("policy");
    let (task, plan) = fixtures::task_plan(16, &endpoint.address);
    ledger.register_task(&task).expect("task");
    ledger.enqueue_provider(&plan).expect("queue");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    let output = Cancellation {
        stopped: Arc::new(AtomicBool::new(false)),
        checkpoint: Mutex::new(None),
    };
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "test-key".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("transport");
    assert!(open_guarded(&mut ledger, &permit, &transport, &output).is_ok());
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 1);
}

proptest::proptest! {
    #![proptest_config(proptest::test_runner::Config::with_cases(16))]
    #[test]
    fn prepared_http_request_is_inert_and_cannot_outlive_revocation(revoked in proptest::bool::ANY, discarded in proptest::bool::ANY) {
        let endpoint=Endpoint::new();
        let directory=tempfile::tempdir().expect("store");
        let mut ledger=Ledger::open(directory.path().join("request.db")).expect("ledger");
        ledger.publish_typed(None,"permit(principal,action,resource);",SCHEMA,1).expect("source");
        let (task,plan)=fixtures::task_plan(16,&endpoint.address);
        ledger.register_task(&task).expect("original task");
        ledger.enqueue_provider(&plan).expect("reservation");
        let eligible=BTreeSet::from(["primary".into()]);
        let permit=ledger.consume_provider("f","infer",&eligible).expect("consume");
        let transport=ProviderTransport::new(BTreeMap::from([("primary".into(),"test-key".into())]),Some(endpoint.root.as_bytes()),endpoint.runtime.handle().clone()).expect("transport");
        let before=ledger.transaction_timings();
        let request=transport.prepare(permit.plan(),permit.route(),permit.protocol()).expect("pure request");
        proptest::prop_assert_eq!(endpoint.calls.load(Ordering::SeqCst),0);
        proptest::prop_assert_eq!(ledger.transaction_timings().transaction_hold.attempts,before.transaction_hold.attempts);
        if revoked {ledger.publish(Some(0),"forbid(principal,action,resource);",2).expect("new fence");}
        if discarded {drop(request);} else {
            let result=ledger.dispatch_provider(&permit,||request.write_and_seal());
            if revoked {proptest::prop_assert!(result.is_err());} else {let sealed=result.expect("guarded actual HTTPS seal");sealed.wait_for_response_headers().expect("headers");}
        }
        proptest::prop_assert_eq!(endpoint.calls.load(Ordering::SeqCst),usize::from(!revoked&&!discarded));
        proptest::prop_assert_eq!(ledger.held("f").expect("held"),4);
        proptest::prop_assert!(ledger.consume_provider("f","infer",&eligible).is_err());
        ledger.close().expect("natural cleanup");
    }
}

#[test]
fn response_header_wait_is_outside_request_and_transaction_timings() {
    let delay = Duration::from_millis(30);
    let endpoint = Endpoint::with_header_delay(delay);
    let directory = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(directory.path().join("ledger.db")).expect("ledger");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("policy");
    let (task, plan) = fixtures::task_plan(16, &endpoint.address);
    ledger.register_task(&task).expect("task");
    ledger.enqueue_provider(&plan).expect("queue");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "test-key".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("transport");
    let output = Cancellation {
        stopped: Arc::new(AtomicBool::new(false)),
        checkpoint: Mutex::new(None),
    };
    let before = ledger.transaction_timings();
    let response = open_guarded(&mut ledger, &permit, &transport, &output).expect("headers");
    let phase = ledger.transaction_timings().since(before);
    assert_eq!(phase.provider_request.attempts, 1);
    // Scope timings stop at seal, before any header read. The paired native
    // benchmark measures this boundary separately from whole-call wall time.
    assert!(phase.transaction_hold.nanos >= phase.provider_request.nanos);
    assert_eq!(ledger.held("f").expect("held"), 4);
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 1);
    eprintln!(
        "header wait native timings: request_ns={} transaction_hold_ns={} commit_ns={}",
        phase.provider_request.nanos, phase.transaction_hold.nanos, phase.commit.nanos
    );
    drop(response);
}

#[test]
fn dropped_sealed_result_closes_sole_driver_without_header_read_or_refund() {
    let endpoint = Endpoint::with_read_mode(Duration::ZERO, true);
    let directory = tempfile::tempdir().expect("directory");
    let path = directory.path().join("ledger.db");
    let mut ledger = Ledger::open(&path).expect("ledger");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("policy");
    let (task, plan) = fixtures::task_plan(16, &endpoint.address);
    ledger.register_task(&task).expect("task");
    ledger.enqueue_provider(&plan).expect("queue");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "test-key".into())]),
        Some(endpoint.root.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("transport");
    let request = transport
        .prepare(permit.plan(), permit.route(), permit.protocol())
        .expect("inert request");
    let sealed = ledger
        .dispatch_provider(&permit, || request.write_and_seal())
        .expect("guard commit and seal");
    // This is the same ownership drop used if the deciding commit fails or its
    // sealed result is lost. It is not an injected native storage-commit fault.
    drop(sealed);
    let deadline = Instant::now() + Duration::from_secs(1);
    while !endpoint.peer_closed.load(Ordering::SeqCst) && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(1));
    }
    assert!(
        endpoint.peer_closed.load(Ordering::SeqCst),
        "detached HTTP driver retained the socket"
    );
    drop(ledger);
    let mut recovered = Ledger::open(path).expect("recover");
    assert!(
        recovered
            .dispatch_provider::<()>(&permit, || panic!("old worker invoked"))
            .is_err()
    );
    assert_eq!(
        recovered
            .provider_receipt("f", "infer")
            .expect("lookup")
            .expect("receipt")
            .held,
        4
    );
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 1);
}

#[test]
fn configured_ca_bundle_preserves_later_approved_root() {
    let endpoint = Endpoint::new();
    let unrelated =
        rcgen::generate_simple_self_signed(vec!["unrelated.invalid".into()]).expect("unrelated CA");
    let bundle = format!("{}{}", unrelated.cert.pem(), endpoint.root);
    let directory = tempfile::tempdir().expect("directory");
    let mut ledger = Ledger::open(directory.path().join("ledger.db")).expect("ledger");
    ledger
        .publish_typed(None, "permit(principal,action,resource);", SCHEMA, 1)
        .expect("policy");
    let (task, plan) = fixtures::task_plan(16, &endpoint.address);
    ledger.register_task(&task).expect("task");
    ledger.enqueue_provider(&plan).expect("queue");
    let permit = ledger
        .consume_provider("f", "infer", &BTreeSet::from(["primary".into()]))
        .expect("consume");
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "test-key".into())]),
        Some(bundle.as_bytes()),
        endpoint.runtime.handle().clone(),
    )
    .expect("bundle");
    assert_eq!(
        transport.inner.tls.alpn_protocols,
        vec![b"http/1.1".to_vec()]
    );
    let output = Cancellation {
        stopped: Arc::new(AtomicBool::new(false)),
        checkpoint: Mutex::new(None),
    };
    assert!(open_guarded(&mut ledger, &permit, &transport, &output).is_ok());
    assert_eq!(endpoint.calls.load(Ordering::SeqCst), 1);
    assert_eq!(ledger.held("f").expect("held"), 4);
}
