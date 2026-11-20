// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Native HTTP fixture. Advisory selection is a test double, not Scheme evidence.
use crate::{runtime::RuntimeOwner, source_owner::SourceOwner};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use weaver_contracts::{FactFeed, FactIntent, SourceAuthority, SourceIdentity, body_digest};

pub fn slot() -> Arc<tokio::sync::OwnedSemaphorePermit> {
    Arc::new(
        Arc::new(tokio::sync::Semaphore::new(1))
            .try_acquire_owned()
            .expect("fixture slot"),
    )
}
pub fn caller() -> SourceIdentity {
    SourceIdentity {
        certificate_sha256: body_digest("http-cert"),
        public_key_sha256: body_digest("http-key"),
        credential_sha256: body_digest("http-source"),
    }
}
pub fn feed() -> FactFeed {
    FactFeed {
        domain: "http-facts".into(),
        authority: SourceAuthority {
            epoch: 0,
            identity: caller(),
        },
        family: "session-a".into(),
        root: "infer".into(),
        dependencies: vec![],
        workflow: None,
        workflow_path: vec![],
        workflow_dag: false,
        workflow_choice: false,
        workflow_selectors: vec![],
    }
}
pub async fn change(owner: &SourceOwner, available: bool) {
    let state = owner.inspect_fact(caller()).await.expect("fact state");
    let barrier = owner
        .stage_fact(
            caller(),
            FactIntent {
                operation_id: format!("fact-{}", state.revision + 1),
                domain: state.domain,
                source_epoch: state.source_epoch,
                revision: state.revision + 1,
                previous_snapshot: state.snapshot,
                expected_floor: state.floor,
                available,
            },
        )
        .await
        .expect("intent");
    let weaver_ledger::FactPreparation::Pending(work) = owner
        .prepare_fact(caller(), barrier)
        .await
        .expect("prepare")
    else {
        panic!("new intent")
    };
    owner
        .resolve_fact(caller(), work, vec!["infer".into()])
        .await
        .expect("resolve");
}
pub async fn register(source: &SourceOwner, endpoint: &str, protocol: &str) {
    let publication = weaver_contracts::Publication {
        operation_id: "http-session-publication".into(),
        expected_revision: None,
        fence: 1,
        policy: include_str!("../../../../prod/policies/provider/provider.cedar")
            .replace("context.family == \"f\"", "context.family like \"turn:*\"")
            .replace("openai.chat-text-sse.v1", protocol)
            .replace(
                "[\"protobuf\", \"arrow\"]",
                "[\"protobuf\", \"arrow\", \"sse\"]",
            ),
        schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
    };
    source
        .publish(caller(), publication.clone())
        .await
        .expect("publish");
    let (mut template, _) = crate::test_fixtures::task_plan(1, endpoint);
    template.family = "session-a".into();
    template.body_digests.clear();
    template.stream_contracts.clear();
    let profile = template.provider_profile.as_mut().expect("profile");
    profile.protocol = protocol.into();
    profile.max_body_bytes = 4096;
    source
        .register_session(
            caller(),
            weaver_contracts::ProviderSessionScope {
                template,
                domains: weaver_contracts::DomainBinding {
                    origin: "session-a".into(),
                    budget: "shared".into(),
                    history: "history".into(),
                    budget_limit: 8,
                },
                max_turns: 4,
                publication: weaver_contracts::PublicationKey {
                    operation_id: publication.operation_id.clone(),
                    digest: publication.digest().expect("publication"),
                },
            },
        )
        .await
        .expect("register");
    change(source, true).await;
}
pub fn advisory(
    runtime: &RuntimeOwner,
    calls: Arc<AtomicUsize>,
) -> tokio::task::JoinHandle<weaver_contracts::Result<()>> {
    let (client, inbox) =
        weaver_governance::source_lane(std::num::NonZeroUsize::new(4).expect("four"));
    runtime
        .attach_governance(client)
        .expect("attach advisory test double");
    runtime
        .spawn_blocking(slot(), move |_| {
            inbox.run_with_cancellable_governor(
                (),
                |_, _, _| panic!("HTTP cannot compile"),
                |_, input| {
                    let weaver_governance::Derivation::SessionTurn(input) = input else {
                        return Err(weaver_governance::SourceError::Contract);
                    };
                    calls.fetch_add(1, Ordering::SeqCst);
                    Ok(weaver_governance::DerivationOutput::SessionTurn(
                        weaver_governance::SessionTurnSelection {
                            scope_commitment: input.scope.digest().expect("scope"),
                            route_indices: vec![0],
                        },
                    ))
                },
            );
            Ok(())
        })
        .expect("advisory task")
}

pub struct ProviderPeer {
    pub endpoint: String,
    pub root: String,
    pub requests: tokio::sync::mpsc::Receiver<String>,
    task: Option<tokio::task::JoinHandle<std::io::Result<()>>>,
    stop: tokio_util::sync::CancellationToken,
    write_failed: Arc<tokio::sync::Notify>,
}
impl ProviderPeer {
    pub async fn finish(mut self) -> Result<std::io::Result<()>, tokio::task::JoinError> {
        self.stop.cancel();
        self.task.take().expect("provider task").await
    }
}
impl Drop for ProviderPeer {
    fn drop(&mut self) {
        self.stop.cancel();
    }
}
pub async fn provider(replies: Vec<String>) -> ProviderPeer {
    let _ = rustls::crypto::ring::default_provider().install_default();
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let certificate =
        rcgen::generate_simple_self_signed(vec!["localhost".into()]).expect("provider cert");
    let root = certificate.cert.pem();
    let tls = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(
            vec![certificate.cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(certificate.signing_key.serialize_der())
                .into(),
        )
        .expect("TLS");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("provider listen");
    let endpoint = format!(
        "https://localhost:{}/v1/chat/completions",
        listener.local_addr().expect("provider address").port()
    );
    let (sender, receiver) = tokio::sync::mpsc::channel(4);
    let stop = tokio_util::sync::CancellationToken::new();
    let stopping = stop.clone();
    let write_failed = Arc::new(tokio::sync::Notify::new());
    let failed = write_failed.clone();
    let task = tokio::spawn(async move {
        let mut replies = replies.into_iter();
        let mut transmission = Ok(());
        loop {
            let (socket, _) = tokio::select! {
                biased;
                accepted=listener.accept()=>accepted.expect("provider accept"),
                ()=stopping.cancelled()=>{assert!(replies.next().is_none(),"all frozen replies consumed");break},
            };
            let reply = replies
                .next()
                .expect("unexpected extra upstream connection");
            socket
                .set_nodelay(true)
                .expect("bounded small-chunk transport");
            let mut stream = tokio_rustls::TlsAcceptor::from(Arc::new(tls.clone()))
                .accept(socket)
                .await
                .expect("provider TLS");
            let mut bytes = Vec::new();
            let boundary = loop {
                let mut chunk = [0; 4096];
                let count = stream.read(&mut chunk).await.expect("provider read");
                assert!(count > 0 && bytes.len() + count < 16_384);
                bytes.extend_from_slice(&chunk[..count]);
                if let Some(end) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                    break end + 4;
                }
            };
            let headers = String::from_utf8(bytes[..boundary].to_vec()).expect("headers");
            let lower = headers.to_ascii_lowercase();
            if lower.starts_with("post /v1/messages ") {
                assert!(lower.contains("x-api-key: provider-secret"));
                assert!(lower.contains("anthropic-version: 2023-06-01"));
            } else {
                assert!(lower.contains("authorization: bearer provider-secret"));
            }
            assert!(!headers.contains("http-client-secret"));
            let length: usize = headers
                .lines()
                .find_map(|line| {
                    line.split_once(':')
                        .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                        .map(|(_, v)| v.trim().parse().expect("length"))
                })
                .expect("body length");
            while bytes.len() - boundary < length {
                let mut chunk = [0; 4096];
                let count = stream.read(&mut chunk).await.expect("body");
                assert!(count > 0);
                bytes.extend_from_slice(&chunk[..count]);
            }
            sender
                .send(
                    String::from_utf8(bytes[boundary..boundary + length].to_vec())
                        .expect("wire body"),
                )
                .await
                .expect("observation");
            let sent: std::io::Result<()> = async {
                stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n").await?;
                let width = if reply.len() <= 65_536 { 7 } else { 16_384 };
                for chunk in reply.as_bytes().chunks(width) {
                    stream
                        .write_all(format!("{:x}\r\n", chunk.len()).as_bytes())
                        .await?;
                    stream.write_all(chunk).await?;
                    stream.write_all(b"\r\n").await?;
                }
                stream.write_all(b"0\r\n\r\n").await?;
                stream.shutdown().await
            }.await;
            // Keep observing the listening socket after a cancelled response.
            // Otherwise a second send could disappear behind this I/O error.
            if transmission.is_ok() {
                transmission = sent;
            }
            if transmission.is_err() {
                failed.notify_one();
            }
        }
        transmission
    });
    ProviderPeer {
        endpoint,
        root,
        requests: receiver,
        task: Some(task),
        stop,
        write_failed,
    }
}

pub fn text_reply() -> String {
    concat!(
        "data: {\"id\":\"r\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null}]}\n\n",
        "data: {\"id\":\"r\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
        "data: {\"id\":\"r\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\n",
        "data: [DONE]\n\n"
    ).into()
}

pub fn settings(database: &std::path::Path, root: &str) -> crate::GrpcConfig {
    use sha2::{Digest, Sha256};
    crate::GrpcConfig {
        owner: crate::ServerConfig {
            database: database.into(),
            principal: "alice".into(),
            token_sha256: Sha256::digest(b"operation-token").into(),
            max_in_flight: 4,
        },
        review_authority: weaver_contracts::ReviewAuthority {
            audience: "test-gateway".into(),
            epoch: 0,
            public_key: "4".repeat(64),
            allow_expansion: false,
            qualified_catalog: None,
        },
        security: crate::RpcSecurity {
            tls: tonic::transport::ServerTlsConfig::new(),
            peer_sha256: [2; 32],
            source_peer_sha256: [3; 32],
            admin_sha256: Sha256::digest(b"source-token").into(),
        },
        metering: None,
        provider_oauth: None,
        provider: weaver_broker::ProviderTransport::new(
            [("primary".into(), "provider-secret".into())].into(),
            Some(root.as_bytes()),
            tokio::runtime::Handle::current(),
        )
        .expect("transport"),
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn upstream_oracle_detects_a_connection_even_when_stop_is_ready() {
    let peer = provider(Vec::new()).await;
    let port = reqwest::Url::parse(&peer.endpoint)
        .expect("peer URL")
        .port()
        .expect("peer port");
    let socket = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .expect("actual extra connection");
    let error = peer
        .finish()
        .await
        .expect_err("observer must detect a queued forbidden connection");
    assert!(error.is_panic());
    let panic = error.into_panic();
    let message = panic
        .downcast_ref::<String>()
        .map(String::as_str)
        .or_else(|| panic.downcast_ref::<&str>().copied())
        .expect("panic text");
    assert!(
        message.contains("unexpected extra upstream connection"),
        "wrong failure: {message}"
    );
    drop(socket);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn upstream_oracle_keeps_observing_after_a_response_disconnect() {
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        let peer = provider(vec!["x".repeat(8 * 1024 * 1024)]).await;
        let client = reqwest::Client::builder()
            .no_proxy()
            .add_root_certificate(
                reqwest::Certificate::from_pem(peer.root.as_bytes()).expect("root"),
            )
            .build()
            .expect("client");
        let response = client
            .post(&peer.endpoint)
            .bearer_auth("provider-secret")
            .body("{}")
            .send()
            .await
            .expect("actual TLS request");
        assert_eq!(response.status(), 200);
        drop(response);
        drop(client);
        peer.write_failed.notified().await;
        let port = reqwest::Url::parse(&peer.endpoint)
            .expect("URL")
            .port()
            .expect("port");
        let socket = tokio::net::TcpStream::connect(("127.0.0.1", port))
            .await
            .expect("oracle must still be listening after the response error");
        let error = peer
            .finish()
            .await
            .expect_err("extra send cannot hide behind a write error");
        assert!(error.is_panic());
        let panic = error.into_panic();
        let text = panic
            .downcast_ref::<String>()
            .map(String::as_str)
            .or_else(|| panic.downcast_ref::<&str>().copied())
            .expect("panic text");
        assert!(
            text.contains("unexpected extra upstream connection"),
            "wrong failure: {text}"
        );
        drop(socket);
    })
    .await
    .expect("bounded disconnect oracle");
}
