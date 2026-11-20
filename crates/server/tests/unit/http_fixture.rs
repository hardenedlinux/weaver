// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Native HTTP fixture. Advisory selection is a test double, not Scheme evidence.
use crate::{runtime::RuntimeOwner, source_owner::SourceOwner};
use std::sync::Arc;
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
pub async fn register(source: &SourceOwner, endpoint: &str) {
    let publication = weaver_contracts::Publication {
        operation_id: "http-session-publication".into(),
        expected_revision: None,
        fence: 1,
        policy: include_str!("../../../../prod/policies/provider/provider.cedar")
            .replace("context.family == \"f\"", "context.family like \"turn:*\"")
            .replace("openai.chat-text-sse.v1", weaver_contracts::CHAT_TURN_SSE)
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
    profile.protocol = weaver_contracts::CHAT_TURN_SSE.into();
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
pub fn advisory(runtime: &RuntimeOwner) -> tokio::task::JoinHandle<weaver_contracts::Result<()>> {
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

pub async fn provider() -> (
    String,
    String,
    tokio::sync::mpsc::Receiver<String>,
    tokio::task::JoinHandle<()>,
) {
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
    let task = tokio::spawn(async move {
        for _ in 0..2 {
            let (socket, _) = listener.accept().await.expect("provider accept");
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
            assert!(
                headers
                    .to_ascii_lowercase()
                    .contains("authorization: bearer provider-secret")
            );
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
            let reply = concat!(
                "data: {\"id\":\"r\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"hello\"},\"finish_reason\":null}]}\n\n",
                "data: {\"id\":\"r\",\"model\":\"model-a\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
                "data: {\"id\":\"r\",\"model\":\"model-a\",\"choices\":[],\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3}}\n\n",
                "data: [DONE]\n\n"
            );
            stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",reply.len()).as_bytes()).await.expect("provider response");
            stream.shutdown().await.expect("provider close");
        }
    });
    (endpoint, root, receiver, task)
}
