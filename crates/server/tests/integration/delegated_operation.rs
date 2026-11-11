// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Actual OIDC/STS, mTLS operation, signed publication and final release boundary.

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error>>;
#[path = "../unit/fixtures.rs"]
mod fixtures;
#[path = "../../../llm/tests/integration/oauth_issuer.rs"]
mod issuer;
mod rpc_fixture;

use ring::signature::{Ed25519KeyPair, KeyPair};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    sync::{Notify, oneshot},
    task::{JoinHandle, JoinSet},
    time::timeout,
};
use tonic::{
    Request,
    transport::{Certificate, Identity, ServerTlsConfig},
};
use weaver_contracts::{ProviderOAuthDeployment, ProviderOAuthGrant, body_digest};
use weaver_server::{GrpcConfig, GrpcListeners, OperationClient, RpcSecurity, ServerConfig, pb};

struct Tasks(Vec<JoinHandle<()>>);
impl Drop for Tasks {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}

async fn private_file(path: &std::path::Path, bytes: impl AsRef<[u8]>) -> TestResult {
    tokio::fs::write(path, bytes).await?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).await?;
    }
    Ok(())
}

async fn provider(
    pki: &rpc_fixture::Pki,
    arrived: Arc<Notify>,
    release: Arc<Notify>,
    count: Arc<AtomicUsize>,
) -> TestResult<(String, JoinHandle<()>)> {
    use rustls::pki_types::pem::PemObject;
    let cert = rustls::pki_types::CertificateDer::from_pem_slice(pki.server.pem.as_bytes())?;
    let key = rustls::pki_types::PrivateKeyDer::from_pem_slice(pki.server.key.as_bytes())?;
    let tls = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()?
    .with_no_client_auth()
    .with_single_cert(vec![cert], key)?;
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(tls));
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let endpoint = format!(
        "https://localhost:{}/v1/chat/completions",
        listener.local_addr()?.port()
    );
    let task = tokio::spawn(async move {
        let mut tasks = JoinSet::new();
        loop {
            tokio::select! {
                connection=listener.accept()=>{
                    let Ok((socket,_))=connection else {break;};
                    let (acceptor,arrived,release,count)=(acceptor.clone(),arrived.clone(),release.clone(),count.clone());
                    tasks.spawn(async move {
                        let result=async {
                            let mut socket=BufReader::new(acceptor.accept(socket).await?);
                            let mut length=0;
                            loop {let mut line=String::new();socket.read_line(&mut line).await?;
                                if line=="\r\n" {break;}
                                if let Some((key,value))=line.split_once(':') && key.eq_ignore_ascii_case("content-length") {length=value.trim().parse::<usize>()?;}
                            }
                            let mut body=vec![0;length];socket.read_exact(&mut body).await?;
                            let n=count.fetch_add(1,Ordering::SeqCst)+1;
                            if n==2 {arrived.notify_one();release.notified().await;}
                            let sse=provider_sse();
                            socket.get_mut().write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{sse}",sse.len()).as_bytes()).await?;
                            Ok::<_,Box<dyn std::error::Error>>(())
                        }.await;
                        let _=result; // A revoked response can be disconnected before its write.
                    });
                }
                _=tasks.join_next(),if !tasks.is_empty()=>{}
            }
        }
    });
    Ok((endpoint, task))
}

fn provider_sse() -> String {
    use serde_json::json;
    let chunks = [
        json!({"id":"one","object":"chat.completion.chunk","model":"model-a","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}),
        json!({"id":"one","object":"chat.completion.chunk","model":"model-a","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}),
        json!({"id":"one","object":"chat.completion.chunk","model":"model-a","choices":[],"usage":{"prompt_tokens":0,"completion_tokens":1,"total_tokens":1}}),
    ];
    let records = chunks
        .into_iter()
        .map(|chunk| format!("data: {chunk}\n\n"))
        .collect::<String>();
    format!("{records}data: [DONE]\n\n")
}

fn request(plan: &weaver_contracts::ProviderPlan) -> pb::ProviderRequest {
    pb::ProviderRequest {
        plan: Some(pb::ProviderPlan {
            family: plan.family.clone(),
            node: plan.node.clone(),
            profile: plan.profile.clone(),
            profile_commitment: plan.profile_commitment.clone(),
            model: plan.model.clone(),
            body: plan.body.as_bytes().to_vec(),
            routes: plan
                .routes
                .iter()
                .map(|r| pb::Route {
                    target: r.target.clone(),
                    endpoint: r.endpoint.clone(),
                })
                .collect(),
            ceiling: plan.ceiling,
            revision: plan.revision,
            fence: plan.fence,
        }),
        encoding: pb::Encoding::Protobuf as i32,
        batch_rows: 1,
        catalog_version: String::new(),
    }
}

fn source<T>(value: T) -> Request<T> {
    let mut request = Request::new(value);
    request.metadata_mut().insert(
        "authorization",
        "Bearer source-token".parse().expect("static metadata"),
    );
    request
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn exchanged_credential_requires_approved_grant_and_revocation_blocks_final_release()
-> TestResult {
    issuer::keys()?;
    timeout(Duration::from_secs(5), async {
        let dir = tempfile::tempdir()?;
        let database = dir.path().join("ledger.db");
        let pki = rpc_fixture::pki();
        let arrived = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let count = Arc::new(AtomicUsize::new(0));
        let (upstream, provider_task) =
            provider(&pki, arrived.clone(), release.clone(), count.clone()).await?;
        let (issuer_url, observed, issuer_task) = issuer::spawn().await?;
        let _tasks = Tasks(vec![provider_task, issuer_task]);
        observed.registered.store(true, Ordering::SeqCst);
        let listeners = GrpcListeners {
            operation: TcpListener::bind("127.0.0.1:0").await?,
            source: TcpListener::bind("127.0.0.1:0").await?,
        };
        let operation_address = listeners.operation.local_addr()?;
        let source_address = listeners.source.local_addr()?;
        let resource = format!("https://{operation_address}/");
        *observed.exchange_resource.lock().await = resource.clone();
        let signer =
            Ed25519KeyPair::from_seed_unchecked(&[71; 32]).map_err(|_| "fixture issuer key")?;
        let reviewer =
            Ed25519KeyPair::from_seed_unchecked(&[72; 32]).map_err(|_| "fixture review key")?;
        let review = weaver_contracts::ReviewAuthority {
            audience: "test-gateway".into(),
            epoch: 0,
            public_key: hex::encode(reviewer.public_key().as_ref()),
            allow_expansion: false,
            qualified_catalog: None,
        };
        let oauth = ProviderOAuthDeployment {
            issuer: "issuer".into(),
            subject: "alice".into(),
            client: "exchange:client".into(),
            audience: "weaver".into(),
            public_key: hex::encode(signer.public_key().as_ref()),
            relay_certificate_sha256: None,
            witness_file: None,
        };
        let (mut task, plan) = fixtures::task_plan(16, &upstream);
        let mut second = plan.clone();
        second.node = "second".into();
        task.nodes.push("second".into());
        task.body_digests
            .insert("second".into(), body_digest(&second.body));
        task.node_cost_bounds.insert("second".into(), 4);
        task.stream_contracts
            .insert("second".into(), second.digest()?);
        let caller = weaver_server::source_certificate_identity(
            &pki.source.der,
            body_digest("source-token"),
        )?;
        let mut ledger = weaver_ledger::Ledger::open(&database)?;
        ledger.install_review_authority(&review)?;
        let publication = weaver_contracts::Publication {
            operation_id: "bootstrap".into(),
            expected_revision: None,
            fence: 1,
            policy: "permit(principal,action,resource);".into(),
            schema: include_str!("../../../../prod/policies/provider/schema.json").into(),
        };
        let context = ledger.with_authenticated_source(&caller, |ledger| {
            let key = ledger.stage_reviewed_authority(&publication)?;
            ledger.publication_review_context(&key)
        })?;
        let mut evidence = weaver_contracts::DeltaReview {
            review: weaver_contracts::PublicationReview {
                publication: context.publication.clone(),
                parent: context.parent,
                artifact: "synthetic fixture review, not a SPEC proof".into(),
            },
            audience: context.reviewer.audience,
            reviewer_epoch: context.reviewer.epoch,
            source_epoch: context.source.epoch,
            source_identity_digest: context.source.identity.digest()?,
            disposition: weaver_contracts::DeltaDisposition::Bootstrap,
            delta: "controlled fixture bootstrap".into(),
            signature: String::new(),
        };
        evidence.signature = hex::encode(
            reviewer
                .sign(&hex::decode(evidence.signing_digest()?)?)
                .as_ref(),
        );
        ledger.with_authenticated_source(&caller, |ledger| {
            ledger.register_delta_review(&evidence)?;
            ledger.publish_authority(&publication)?;
            ledger.register_published_task(&task, &context.publication)
        })?;
        ledger.close()?;
        let settings = GrpcConfig {
            metering: None,
            provider_oauth: Some(oauth.clone()),
            review_authority: review,
            owner: ServerConfig {
                database,
                principal: "alice".into(),
                token_sha256: Sha256::digest(b"operation-token").into(),
                max_in_flight: 16,
            },
            security: RpcSecurity {
                tls: ServerTlsConfig::new()
                    .identity(Identity::from_pem(&pki.server.pem, &pki.server.key))
                    .client_ca_root(Certificate::from_pem(&pki.ca)),
                peer_sha256: Sha256::digest(&pki.operation.der).into(),
                source_peer_sha256: Sha256::digest(&pki.source.der).into(),
                admin_sha256: Sha256::digest(b"source-token").into(),
            },
            provider: weaver_broker::ProviderTransport::new(
                BTreeMap::from([("primary".into(), "provider-key".into())]),
                Some(pki.ca.as_bytes()),
                tokio::runtime::Handle::current(),
            )?,
        };
        let (stop, stopped) = oneshot::channel();
        let serving = tokio::spawn(weaver_server::serve_grpc(listeners, settings, async {
            let _ = stopped.await;
        }));
        for (name, bytes) in [
            ("ca", pki.ca.as_bytes()),
            ("certificate", pki.operation.pem.as_bytes()),
            ("key", pki.operation.key.as_bytes()),
            ("operation-token", b"operation-token".as_slice()),
        ] {
            private_file(&dir.path().join(name), bytes).await?;
        }
        let config = dir.path().join("weaver.toml");
        tokio::fs::write(
            &config,
            format!(
                r#"
[profiles.gateway]
kind = "delegated"
endpoint = "{resource}"
timeout_ms = 1000
[profiles.gateway.identity]
issuer = "{issuer_url}"
client_id = "oaiapp-fixture"
redirect_uri = "http://127.0.0.1:1455/callback"
resource = "{issuer_url}/v1"
scopes = ["openid", "profile", "model.invoke"]
token_file = "auth/account.json"
login_timeout_ms = 2000
[profiles.gateway.exchange]
token_url = "{issuer_url}/exchange"
client_id = "exchange:client"
audience = "weaver"
scopes = ["provider:execute"]
[profiles.gateway.operation]
server_name = "localhost"
ca = "ca"
certificate = "certificate"
key = "key"
[profiles.gateway.operation.credential]
file = "operation-token"
"#
            ),
        )
        .await?;
        let prepared = weaver_llm::Configuration::load(&config).await?;
        let mut client = match OperationClient::from_config(
            &prepared,
            "gateway",
            Duration::from_secs(1),
        )
        .await
        {
            Ok(client) => client,
            Err(error) => {
                if serving.is_finished() {
                    return Err(format!("server startup: {:?}", serving.await?).into());
                }
                return Err(error.into());
            }
        };
        let attempt = client.identity().start_authorization().await?;
        let url = oauth2_url(attempt.authorization_url())?;
        *observed.nonce.lock().await = url["nonce"].clone();
        *observed.challenge.lock().await = url["code_challenge"].clone();
        let callback = format!(
            "http://127.0.0.1:1455/callback?state={}&code=one-time-code",
            url["state"]
        );
        attempt.finish(&callback).await?;
        let credential = client.identity().delegated_credential(&resource).await?;
        for (peer, bearer) in [
            (&pki.next, "Bearer operation-token"),
            (&pki.source, "Bearer operation-token"),
            (&pki.operation, "Bearer wrong-operation-token"),
        ] {
            let wrong = weaver_llm::PreparedOperation {
                endpoint: resource.clone(),
                server_name: "localhost".into(),
                ca: pki.ca.as_bytes().to_vec().into(),
                certificate: peer.pem.as_bytes().to_vec().into(),
                key: peer.key.as_bytes().to_vec().into(),
                operation_bearer: bearer.parse()?,
                identity: client.identity().clone(),
            };
            let mut wrong = OperationClient::connect(wrong, Duration::from_secs(1)).await?;
            assert_eq!(
                wrong
                    .execute(request(&plan))
                    .await
                    .err()
                    .ok_or("wrong operation identity admitted")?
                    .code(),
                tonic::Code::Unauthenticated
            );
        }
        let mut missing = client.execute(request(&plan)).await?.into_inner();
        assert!(missing.message().await.is_err());
        assert_eq!(count.load(Ordering::SeqCst), 0);
        let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
        let mut grant = ProviderOAuthGrant {
            issuer: oauth.issuer,
            subject: oauth.subject,
            client: oauth.client,
            audience: oauth.audience,
            scopes: vec!["provider:execute".into()],
            token_hash: credential.token_sha256(),
            certificate_sha256: hex::encode(Sha256::digest(&pki.operation.der)),
            not_before: now - 1,
            expires_at: credential.expires_at().min(now + 60),
            issuer_epoch: 0,
            parent_token_hash: None,
            signature: String::new(),
        };
        grant.signature = hex::encode(signer.sign(&hex::decode(grant.signing_digest()?)?).as_ref());
        let source_channel = rpc_fixture::connect(source_address, &pki.source, &pki.ca).await;
        let wire = pb::ProviderOAuthGrant {
            issuer: grant.issuer,
            subject: grant.subject,
            client: grant.client,
            audience: grant.audience,
            scopes: grant.scopes,
            token_hash: grant.token_hash.clone(),
            certificate_sha256: grant.certificate_sha256,
            not_before: grant.not_before,
            expires_at: grant.expires_at,
            signature: grant.signature,
            issuer_epoch: 0,
            parent_token_hash: String::new(),
        };
        let mut publisher = pb::gateway_client::GatewayClient::new(source_channel.clone());
        publisher
            .change_provider_o_auth(source(pb::ProviderOAuthChange {
                action: Some(pb::provider_o_auth_change::Action::Grant(wire)),
            }))
            .await?;
        let mut normal = client.execute(request(&plan)).await?.into_inner();
        let mut text = String::new();
        while let Some(frame) = normal.message().await? {
            if let Some(pb::provider_frame::Payload::Event(event)) = frame.payload {
                text.push_str(&event.text);
            }
        }
        assert_eq!(text, "Hi");
        assert_eq!(count.load(Ordering::SeqCst), 1);
        let mut pending = client.execute(request(&second)).await?.into_inner();
        arrived.notified().await;
        let _: pb::Empty = rpc_fixture::unary(
            source_channel.clone(),
            "source-token",
            "/weaver.gateway.v1.Gateway/ChangeProviderOAuth",
            pb::ProviderOAuthChange {
                action: Some(pb::provider_o_auth_change::Action::RevokeTokenHash(
                    grant.token_hash,
                )),
            },
        )
        .await?;
        release.notify_one();
        assert!(pending.message().await.is_err());
        assert_eq!(observed.exchanges.load(Ordering::SeqCst), 1);
        assert_eq!(count.load(Ordering::SeqCst), 2);
        drop(pending);
        drop(normal);
        drop(missing);
        drop(publisher);
        drop(source_channel);
        drop(client);
        stop.send(()).map_err(|_| "server stopped early")?;
        serving.await??;
        Ok::<_, Box<dyn std::error::Error>>(())
    })
    .await?
}

fn oauth2_url(url: &str) -> TestResult<BTreeMap<String, String>> {
    Ok(url::Url::parse(url)?.query_pairs().into_owned().collect())
}
