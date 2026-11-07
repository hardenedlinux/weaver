// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use criterion::{BatchSize, Criterion, criterion_group};
use std::{
    collections::BTreeMap,
    hint::black_box,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    thread,
    time::Duration,
};
use weaver_broker::{ProviderExecution, ProviderOutput, ProviderTransport, execute_provider};
use weaver_contracts::{ProviderEvent, ProviderRoute, Result};
#[path = "../../contracts/benches/support/fixtures.rs"]
mod fixtures;
#[path = "../../policy/benches/support/fixtures.rs"]
mod policy_fixture;
#[path = "../../ledger/benches/support/provider_store.rs"]
mod stores;
struct Sink {
    events: usize,
}
impl ProviderOutput for Sink {
    fn finish_delivery(
        &mut self,
        _: &mut weaver_ledger::Ledger,
        _: &weaver_ledger::ProviderDispatch,
        _: &str,
    ) -> Result<()> {
        Ok(())
    }

    type Slot = ();
    type PreparedFrame = usize;
    fn stopped(&self) -> bool {
        false
    }
    fn reserve(&mut self) -> Result<()> {
        Ok(())
    }
    fn prepare(_: &ProviderRoute, _: &str, events: &[ProviderEvent], _: &str) -> Result<usize> {
        Ok(events.len())
    }
    fn emit(&mut self, _: (), count: usize, _: weaver_ledger::ProviderDelivery) -> Result<()> {
        self.events += count;
        Ok(())
    }
}
#[path = "../tests/unit/runtime.rs"]
mod fixture_runtime;
struct Provider {
    runtime: tokio::runtime::Runtime,
    address: std::net::SocketAddr,
    endpoint: String,
    pem: String,
    stopped: Arc<AtomicBool>,
    delay: Arc<AtomicU64>,
    calls: Arc<AtomicUsize>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Provider {
    fn start() -> Self {
        let cert = rcgen::generate_simple_self_signed(vec!["localhost".into()])
            .expect("fixture certificate");
        let pem = cert.cert.pem();
        let key = rustls::pki_types::PrivatePkcs8KeyDer::from(cert.signing_key.serialize_der());
        let config = Arc::new(
            rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .expect("TLS versions")
            .with_no_client_auth()
            .with_single_cert(vec![cert.cert.der().clone()], key.into())
            .expect("fixture TLS"),
        );
        let listener = TcpListener::bind("127.0.0.1:0").expect("fixture listener");
        let address = listener.local_addr().expect("fixture address");
        let stopped = Arc::new(AtomicBool::new(false));
        let closing = stopped.clone();
        let delay = Arc::new(AtomicU64::new(0));
        let calls = Arc::new(AtomicUsize::new(0));
        let header_delay = delay.clone();
        let observed_calls = calls.clone();
        let worker = thread::spawn(move || {
            loop {
                let (socket, _) = listener.accept().expect("fixture accept");
                if closing.load(Ordering::SeqCst) {
                    break;
                }
                socket
                    .set_read_timeout(Some(Duration::from_secs(1)))
                    .expect("read deadline");
                socket
                    .set_write_timeout(Some(Duration::from_secs(1)))
                    .expect("write deadline");
                let connection =
                    rustls::ServerConnection::new(config.clone()).expect("fixture TLS connection");
                let mut stream = rustls::StreamOwned::new(connection, socket);
                read_request(&mut stream);
                observed_calls.fetch_add(1, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(header_delay.load(Ordering::SeqCst)));
                let body = concat!(
                    "data: {\"id\":\"s\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"governed\"},\"finish_reason\":null}]}\n\n",
                    "data: {\"id\":\"s\",\"object\":\"chat.completion.chunk\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
                    "data: [DONE]\n\n"
                );
                write!(stream,"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).expect("fixture response");
                stream.flush().expect("fixture flush");
            }
        });
        Self {
            runtime: fixture_runtime::fixture_runtime(None),
            address,
            endpoint: format!("https://localhost:{}/v1/chat/completions", address.port()),
            pem,
            stopped,
            delay,
            calls,
            worker: Some(worker),
        }
    }
}
impl Drop for Provider {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::SeqCst);
        let _ = TcpStream::connect_timeout(&self.address, Duration::from_secs(1));
        if let Some(worker) = self.worker.take() {
            worker.join().expect("fixture natural exit");
        }
    }
}
fn read_request(stream: &mut impl Read) {
    let mut bytes = Vec::new();
    let mut buffer = [0; 4096];
    loop {
        let count = stream.read(&mut buffer).expect("fixture request");
        assert!(count > 0);
        bytes.extend_from_slice(&buffer[..count]);
        assert!(bytes.len() <= 16384);
        if let Some(end) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
            let headers = std::str::from_utf8(&bytes[..end]).expect("headers");
            let length = headers
                .lines()
                .filter_map(|line| line.split_once(':'))
                .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                .map(|(_, value)| value.trim().parse::<usize>().expect("length"))
                .expect("bounded request body");
            if bytes.len() >= end + 4 + length {
                return;
            }
        }
    }
}
fn guarded_provider(c: &mut Criterion) {
    let provider = Provider::start();
    let transport = ProviderTransport::new(
        BTreeMap::from([("primary".into(), "benchmark-key".into())]),
        Some(provider.pem.as_bytes()),
        provider.runtime.handle().clone(),
    )
    .expect("transport");
    c.bench_function("broker/https_guarded_sse_three_events", |b| {
        b.iter_batched(
            || stores::fresh(128, &provider.endpoint),
            |(temp, mut ledger, plan)| {
                let mut sink = Sink { events: 0 };
                execute_provider(
                    &mut ledger,
                    ProviderExecution {
                        plan: &plan,
                        transport: &transport,
                        format: "protobuf",
                        batch_rows: 1,
                    },
                    &mut sink,
                )
                .expect("guarded provider execution");
                assert_eq!(sink.events, 3);
                assert_eq!(ledger.held("f").expect("held"), 4);
                black_box((temp, ledger, sink.events))
            },
            BatchSize::PerIteration,
        )
    });
}
#[path = "../src/provider/anthropic_sse.rs"]
mod anthropic_sse;
#[path = "../src/provider/sse_buffer.rs"]
mod sse_buffer;

fn anthropic_decode(c: &mut Criterion) {
    use weaver_contracts::ProviderEventKind;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .build()
        .expect("Tokio SSE benchmark runtime");
    let mut data = String::new();
    for (event, fields) in [
        (
            "message_start",
            r#""message":{"model":"fixture","role":"assistant","content":[],"usage":{"input_tokens":1,"output_tokens":0}}"#,
        ),
        (
            "content_block_start",
            r#""index":0,"content_block":{"type":"text","text":""}"#,
        ),
    ] {
        data.push_str(&format!(
            "event: {event}\ndata: {{\"type\":\"{event}\",{fields}}}\n\n"
        ));
    }
    for _ in 0..64 {
        data.push_str("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"fragment\"}}\n\n");
    }
    data.push_str("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":64}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n");
    c.bench_function("broker/anthropic_sse_64_deltas", |b| {
        b.to_async(&runtime).iter(|| async {
            let mut decoder = anthropic_sse::Decoder::new(black_box(data.as_bytes()), "fixture");
            loop {
                let event = black_box(decoder.next().await.expect("bounded provider event"));
                if event.kind == ProviderEventKind::Done {
                    break;
                }
            }
            assert_eq!(black_box(decoder.tokens()), [1, 0, 0, 64]);
        })
    });
    c.bench_function("broker/anthropic_buffered_sse_64_deltas", |b| {
        b.to_async(&runtime).iter(|| async {
            let mut decoder = anthropic_sse::Decoder::new(black_box(data.as_bytes()), "fixture");
            loop {
                let event = match decoder
                    .next_buffered()
                    .await
                    .expect("bounded buffered event")
                {
                    Some(event) => event,
                    None => decoder.next().await.expect("bounded provider event"),
                };
                let event = black_box(event);
                if event.kind == ProviderEventKind::Done {
                    break;
                }
            }
            assert_eq!(black_box(decoder.tokens()), [1, 0, 0, 64]);
        })
    });
}
#[path = "../src/provider/wif_cache.rs"]
mod wif_cache;

fn wif_cache_hit(c: &mut Criterion) {
    let cache = std::sync::Mutex::new(Some(wif_cache::AccessToken {
        value: Arc::from("synthetic"),
        expires: tokio::time::Instant::now() + Duration::from_secs(600),
    }));
    c.bench_function("broker/wif_cached_token", |b| {
        b.iter(|| {
            let guard = cache.lock().expect("fixture cache");
            let token = wif_cache::reusable(black_box(guard.as_ref())).expect("current token");
            black_box(token.value)
        })
    });
}
criterion_group! {name=benches;config=Criterion::default().sample_size(30).warm_up_time(Duration::from_secs(1)).measurement_time(Duration::from_secs(2));targets=guarded_provider,anthropic_decode,wif_cache_hit}
#[path = "support/header_seal.rs"]
mod header_seal;
fn main() {
    if std::env::args().any(|arg| arg == "--weaver-header-seal") {
        header_seal::run();
        return;
    }
    benches();
    Criterion::default().configure_from_args().final_summary();
}
