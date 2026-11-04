// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use super::{AnthropicWifConfig, ExchangeResponse, Federation, IoRuntime, validate_response};
use std::{
    io::{BufRead, BufReader, Read, Write},
    net::TcpListener,
    sync::Arc,
    thread,
    time::Duration,
};
use tokio::time::Instant;

proptest::proptest! {
    #[test]
    fn only_current_least_scope_is_accepted(lifetime in 0u64..3700, inference in proptest::bool::ANY) {
        let response = ExchangeResponse {
            access_token: "sk-ant-oat01-synthetic".into(),
            token_type: "Bearer".into(),
            expires_in: lifetime,
            scope: if inference { "workspace:inference" } else { "workspace:developer" }.into(),
        };
        let valid = validate_response(response, Instant::now()).is_ok();
        proptest::prop_assert_eq!(valid, inference && (11..=3600).contains(&lifetime));
    }
}

#[test]
fn synthetic_tls_exchange_refreshes_rotated_assertion() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let tls = rcgen::generate_simple_self_signed(vec!["api.anthropic.com".into()])
        .expect("fixture certificate");
    let root = reqwest::Certificate::from_pem(tls.cert.pem().as_bytes()).expect("fixture root");
    let private = rustls::pki_types::PrivatePkcs8KeyDer::from(tls.signing_key.serialize_der());
    let server = Arc::new(
        rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .expect("versions")
        .with_no_client_auth()
        .with_single_cert(vec![tls.cert.der().clone()], private.into())
        .expect("fixture TLS"),
    );
    let listener = TcpListener::bind("127.0.0.1:0").expect("fixture listener");
    let address = listener.local_addr().expect("fixture address");
    let worker = thread::spawn(move || {
        listener
            .set_nonblocking(true)
            .expect("fixture accept bounds");
        for expected in ["synthetic.first.jwt", "synthetic.second.jwt"] {
            let deadline = std::time::Instant::now() + Duration::from_secs(8);
            let socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error)
                        if error.kind() == std::io::ErrorKind::WouldBlock
                            && std::time::Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(_) => panic!("local exchange did not connect"),
                }
            };
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .expect("read bound");
            socket
                .set_write_timeout(Some(Duration::from_secs(3)))
                .expect("write bound");
            socket
                .set_nonblocking(false)
                .expect("fixture blocking socket");
            let stream = rustls::StreamOwned::new(
                rustls::ServerConnection::new(server.clone()).expect("TLS"),
                socket,
            );
            let mut stream = BufReader::new(stream);
            let mut line = String::new();
            stream.read_line(&mut line).expect("request line");
            assert_eq!(line, "POST /v1/oauth/token HTTP/1.1\r\n");
            let mut length = 0;
            loop {
                line.clear();
                assert!(stream.read_line(&mut line).expect("request header") > 0);
                if line == "\r\n" {
                    break;
                }
                if let Some(n) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    length = n.trim().parse::<usize>().expect("request length");
                }
            }
            assert!((1..=2048).contains(&length));
            let mut body = vec![0; length];
            stream.read_exact(&mut body).expect("request body");
            let body: serde_json::Value = weaver_contracts::decode(&body).expect("exchange JSON");
            assert_eq!(body["assertion"], expected);
            assert_eq!(body["workspace_id"], "wrkspc_fixture");
            assert_eq!(body["federation_rule_id"], "fdrl_fixture");
            assert_eq!(
                body["grant_type"],
                "urn:ietf:params:oauth:grant-type:jwt-bearer"
            );
            let reply = format!(
                r#"{{"access_token":"sk-ant-oat01-{expected}","token_type":"Bearer","expires_in":60,"scope":"workspace:inference"}}"#
            );
            write!(
                stream.get_mut(),
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                reply.len(),
                reply
            )
            .expect("exchange reply");
            stream.get_mut().flush().expect("flush exchange");
        }
    });
    let dir = tempfile::tempdir().expect("fixture directory");
    let assertion_file = dir.path().join("synthetic-assertion");
    std::fs::write(&assertion_file, "synthetic.first.jwt").expect("synthetic JWT");
    let federation = Federation::new(AnthropicWifConfig {
        assertion_file: assertion_file.clone(),
        federation_rule_id: "fdrl_fixture".into(),
        organization_id: "00000000-0000-0000-0000-000000000000".into(),
        service_account_id: "svac_fixture".into(),
        workspace_id: "wrkspc_fixture".into(),
    })
    .expect("fixture federation");
    let runtime = crate::provider::test_runtime::fixture_runtime();
    let io = IoRuntime {
        handle: runtime.handle().clone(),
    };
    // The client trusts only the fixture certificate and resolves the fixed name
    // to the loopback listener. No real credential or remote network is used.
    let client = reqwest::Client::builder()
        .https_only(true)
        .no_proxy()
        .tls_certs_only([root])
        .resolve("api.anthropic.com", address)
        .redirect(reqwest::redirect::Policy::none())
        .retry(reqwest::retry::never())
        .build()
        .expect("fixture client");
    let first = federation.token(&client, &io).expect("first exchange");
    let hit = federation.token(&client, &io).expect("cached exchange");
    assert!(Arc::ptr_eq(&first.value, &hit.value));
    federation
        .cached
        .lock()
        .expect("fixture cache")
        .as_mut()
        .expect("token")
        .expires = Instant::now();
    std::fs::write(&assertion_file, "synthetic.second.jwt").expect("rotated synthetic JWT");
    let second = federation.token(&client, &io).expect("refreshed exchange");
    assert_eq!(second.value.as_ref(), "sk-ant-oat01-synthetic.second.jwt");
    worker.join().expect("fixture natural exit");
}
