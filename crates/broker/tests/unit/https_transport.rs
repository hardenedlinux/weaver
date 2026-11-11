// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{HttpsTransport, SendObservation};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
    net::TcpListener,
    sync::Arc,
    thread,
    time::{Duration, Instant},
};
use weaver_contracts::{Proposal, Task, body_digest};
use weaver_ledger::Ledger;

fn exercise(response: Option<&'static [u8]>) -> (SendObservation, usize, u64) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("loopback bind");
    let port = listener.local_addr().expect("address").port();
    listener.set_nonblocking(true).expect("nonblocking");
    let certified =
        rcgen::generate_simple_self_signed(vec!["localhost".into()]).expect("certificate");
    let certificate = certified.cert.der().clone();
    let key = rustls::pki_types::PrivatePkcs8KeyDer::from(certified.signing_key.serialize_der());
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .expect("protocols")
    .with_no_client_auth()
    .with_single_cert(vec![certificate.clone()], key.into())
    .expect("TLS config");
    let worker = thread::spawn(move || {
        let start = Instant::now();
        let mut count = 0;
        while start.elapsed() < Duration::from_secs(2) {
            match listener.accept() {
                Ok((socket, _)) => {
                    count += 1;
                    socket
                        .set_nonblocking(false)
                        .expect("accepted blocking mode");
                    socket
                        .set_read_timeout(Some(Duration::from_secs(1)))
                        .expect("read deadline");
                    socket
                        .set_write_timeout(Some(Duration::from_secs(1)))
                        .expect("write deadline");
                    let connection =
                        rustls::ServerConnection::new(Arc::new(config.clone())).expect("server");
                    let mut stream = rustls::StreamOwned::new(connection, socket);
                    let mut buffer = [0u8; 4096];
                    let read = stream.read(&mut buffer).expect("TLS request read");
                    assert!(read > 0, "request was empty");
                    if let Some(bytes) = response {
                        stream.write_all(bytes).expect("TLS response write");
                        stream.flush().expect("TLS response flush");
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(e) => panic!("accept: {e}"),
            }
        }
        count
    });
    let root = reqwest::Certificate::from_der(certificate.as_ref()).expect("root");
    let client = reqwest::blocking::Client::builder()
        .tls_certs_only([root])
        .resolve("localhost", (std::net::Ipv4Addr::LOCALHOST, port).into())
        .no_proxy()
        .https_only(true)
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .timeout(Duration::from_secs(1))
        .pool_max_idle_per_host(0)
        .build()
        .expect("client");
    let transport = HttpsTransport {
        client,
        credentials: BTreeMap::new(),
    };
    let temp = tempfile::tempdir().expect("temp");
    let mut ledger = Ledger::open(temp.path().join("ledger.db")).expect("ledger");
    ledger
        .publish(None, "permit(principal,action,resource);", 1)
        .expect("publish");
    let endpoint = format!("https://localhost:{port}/v1/chat/completions");
    let body = r#"{"model":"m","messages":[]}"#.to_string();
    let task = Task {
        provider_profile: None,
        family: "f".into(),
        principal: "alice".into(),
        profile: "p".into(),
        nodes: vec!["n".into()],
        targets: vec!["t".into()],
        endpoints: [("t".into(), endpoint.clone())].into(),
        body_digests: [("n".into(), body_digest(&body))].into(),
        stream_contracts: Default::default(),
        node_cost_bounds: [("n".into(), 1)].into(),
        models: vec!["m".into()],
        budget: 5,
    };
    ledger.register_task(&task).expect("register");
    ledger
        .enqueue(&Proposal {
            family: "f".into(),
            node: "n".into(),
            profile: "p".into(),
            target: "t".into(),
            endpoint,
            model: "m".into(),
            body,
            ceiling: 5,
            revision: 0,
            fence: 1,
        })
        .expect("enqueue");
    let (_, observation) = crate::execute(&mut ledger, "f", "n", &transport).expect("execute");
    assert!(crate::execute(&mut ledger, "f", "n", &transport).is_err());
    (
        observation,
        worker.join().expect("join"),
        ledger.held("f").expect("held"),
    )
}

#[test]
fn redirect_is_observed_without_following_or_refunding() {
    let (observation,calls,held)=exercise(Some(b"HTTP/1.1 307 Temporary Redirect\r\nLocation: https://localhost:1/forged\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
    assert!(matches!(observation, SendObservation::ResponseHeaders(307)));
    assert_eq!(calls, 1);
    assert_eq!(held, 5);
}

#[test]
fn partial_transport_failure_is_unknown_and_never_retried() {
    let (observation, calls, held) = exercise(None);
    assert!(matches!(observation, SendObservation::Indeterminate));
    assert_eq!(calls, 1);
    assert_eq!(held, 5);
}

#[test]
fn destination_aliases_credentials_and_http_are_rejected() {
    for endpoint in [
        "http://example.invalid/",
        "https://user:secret@example.invalid/",
        "https://example.invalid/#fragment",
        "https://EXAMPLE.invalid/",
    ] {
        assert!(HttpsTransport::validate_endpoint(endpoint).is_err());
    }
}

#[test]
fn provider_endpoint_guard_preserves_anthropic_source_path_constraints() {
    use weaver_contracts::ProviderProtocol;
    assert!(
        HttpsTransport::validate_provider_endpoint(
            "https://provider.invalid/v1/messages",
            ProviderProtocol::Anthropic
        )
        .is_ok()
    );
    for endpoint in [
        "http://provider.invalid/v1/messages",
        "https://provider.invalid/other",
        "https://provider.invalid/v1/messages?",
        "https://provider.invalid/v1/messages#fragment",
    ] {
        assert!(
            HttpsTransport::validate_provider_endpoint(endpoint, ProviderProtocol::Anthropic)
                .is_err()
        );
    }
    assert!(
        HttpsTransport::validate_provider_endpoint(
            "https://provider.invalid/v1/chat/completions",
            ProviderProtocol::OpenAi
        )
        .is_ok()
    );
}
