// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Actual approved SDK graph on the server's existing tracked blocking owner.
use std::{cell::Cell, rc::Rc, sync::Arc, thread::ThreadId};
use tokio::sync::{Semaphore, oneshot};
use weaver_governance::{OwnedSource, SchemeCompiler, SourceError};
use weaver_server::ServiceRuntime;
#[path = "../../../governance/tests/unit/fixture.rs"]
mod fixture;
mod rpc_fixture;

struct Compiler {
    compiler: Option<SchemeCompiler>,
    owner: ThreadId,
    local: Rc<Cell<usize>>,
    cleanup: Option<oneshot::Sender<usize>>,
    pause: Option<(oneshot::Sender<()>, std::sync::mpsc::Receiver<()>)>,
}
impl Compiler {
    fn compile(&mut self, source: &OwnedSource) -> Result<OwnedSource, SourceError> {
        assert_eq!(std::thread::current().id(), self.owner);
        self.local.set(self.local.get() + 1);
        if self.local.get() == 3
            && let Some((entered, release)) = self.pause.take()
        {
            let _ = entered.send(());
            release
                .recv_timeout(std::time::Duration::from_secs(3))
                .map_err(|_| SourceError::Scheme)?;
        }
        self.compiler
            .as_mut()
            .ok_or(SourceError::Scheme)?
            .compile(source)
    }
}
impl Drop for Compiler {
    fn drop(&mut self) {
        assert_eq!(std::thread::current().id(), self.owner);
        drop(self.compiler.take());
        if let Some(cleanup) = self.cleanup.take() {
            let _ = cleanup.send(self.local.get());
        }
    }
}
#[tokio::test]
async fn actual_scheme_vm_is_owner_local_and_cleanup_precedes_shared_drain() {
    use sha2::{Digest, Sha256};
    use tonic::transport::{Certificate, Identity, ServerTlsConfig};
    use weaver_server::{GrpcConfig, GrpcListeners, RpcSecurity, ServerConfig, pb};
    const COMPILE: &str = "/weaver.gateway.v1.Gateway/CompileSource";
    let _ = rustls::crypto::ring::default_provider().install_default();
    let pki = rpc_fixture::pki();
    let source_digest = hex::encode(Sha256::digest(b"source-token"));
    let source_identity =
        weaver_server::source_certificate_identity(&pki.source.der, source_digest)
            .expect("actual source leaf/SPKI");
    let authority = weaver_contracts::SourceAuthority {
        epoch: 0,
        identity: source_identity.clone(),
    };
    let runtime = ServiceRuntime::new();
    let capacity = std::thread::available_parallelism().expect("host budget");
    let permits = Arc::new(Semaphore::new(capacity.get()));
    let slot = Arc::new(permits.clone().try_acquire_owned().expect("worker budget"));
    let (cleanup, cleaned) = oneshot::channel();
    let (entered, started) = oneshot::channel();
    let (release, wait) = std::sync::mpsc::channel();
    let worker = runtime
        .start_governance(slot, capacity, move || {
            assert_eq!(weaver_policy_ffi::weaver_policy_abi_v1(), 0x0001_0000);
            let mut program = SchemeCompiler::initialize().expect("production linked compiler");
            let mut declined = fixture::source();
            declined.publication.policy = "not a Cedar policy".into();
            let declined = OwnedSource::from_source(declined).expect("inert candidate");
            assert!(
                matches!(program.compile(&declined), Err(SourceError::Contract)),
                "semantic rejection must not become a terminal SDK failure"
            );
            eprintln!(
                "server governance SDK capabilities={:?}",
                gerbil_scheme::VmCapabilities::linked()
            );
            let mut compiler = Compiler {
                compiler: Some(program),
                owner: std::thread::current().id(),
                local: Rc::new(Cell::new(0)),
                cleanup: Some(cleanup),
                pause: Some((entered, wait)),
            };
            Ok(move |source: &OwnedSource| compiler.compile(source))
        })
        .await
        .expect("approved compiler initialized on worker");
    let mut original = fixture::source();
    original.publication.expected_revision = None;
    let catalog = weaver_governance::ProducerCatalog::from_entries(vec![
        weaver_governance::ApprovedProducer::new(
            "approved-AA".into(),
            authority.clone(),
            OwnedSource::from_source(original.clone()).expect("original"),
        )
        .expect("host binding"),
    ])
    .expect("catalog");
    worker
        .publish_producers(catalog)
        .expect("publish immutable catalog");
    let client = runtime.producers().expect("installed producer set");
    let directory = tempfile::tempdir().expect("database directory");
    let database = directory.path().join("state.db");
    let listeners = GrpcListeners {
        operation: tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("operation"),
        source: tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("source"),
    };
    let source_address = listeners.source.local_addr().expect("source address");
    let operation_address = listeners.operation.local_addr().expect("operation address");
    let settings = GrpcConfig {
        metering: None,
        provider_oauth: None,
        review_authority: weaver_contracts::ReviewAuthority {
            audience: "test-gateway".into(),
            epoch: 0,
            public_key: "4".repeat(64),
            allow_expansion: false,
            qualified_catalog: None,
        },
        owner: ServerConfig {
            database: database.clone(),
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
            Default::default(),
            None,
            tokio::runtime::Handle::current(),
        )
        .expect("no provider credentials"),
    };
    let (stop, stopped) = oneshot::channel();
    let serving = runtime.clone();
    let server = tokio::spawn(async move {
        weaver_server::serve_grpc_with_runtime(listeners, settings, serving, async {
            let _ = stopped.await;
        })
        .await
    });
    let source = rpc_fixture::connect(source_address, &pki.source, &pki.ca).await;
    let operation = rpc_fixture::connect(operation_address, &pki.operation, &pki.ca).await;
    let denied: Result<pb::CompiledSource, _> = rpc_fixture::unary(
        operation,
        "operation-token",
        COMPILE,
        pb::ProducerRequest {
            producer: "approved-AA".into(),
        },
    )
    .await;
    assert_eq!(
        denied.expect_err("operation cannot compile").code(),
        tonic::Code::PermissionDenied
    );
    let consumer = directory.path().join("pki");
    std::fs::create_dir(&consumer).expect("PKI directory");
    for (name, value) in [
        ("ca.pem", &pki.ca),
        ("source.pem", &pki.source.pem),
        ("source.key", &pki.source.key),
        ("operation.pem", &pki.operation.pem),
        ("operation.key", &pki.operation.key),
        ("server.pem", &pki.server.pem),
        ("server.key", &pki.server.key),
    ] {
        std::fs::write(consumer.join(name), value).expect("ephemeral test identity");
    }
    let go = std::env::var_os("WEAVER_TEST_GO").unwrap_or_else(|| "go".into());
    let independent = tokio::process::Command::new(go)
        .current_dir(std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../go"))
        .args([
            "test",
            "-count=1",
            "-race",
            "./internal/controlplane",
            "-run",
            "^TestApprovedSourceMTLSBootstrap$",
            "-v",
        ])
        .env("WEAVER_TEST_APPROVED_SOURCE", source_address.to_string())
        .env(
            "WEAVER_TEST_APPROVED_OPERATION",
            operation_address.to_string(),
        )
        .env("WEAVER_TEST_APPROVED_PKI", &consumer)
        .output()
        .await
        .expect("independent Go consumer");
    assert!(
        independent.status.success(),
        "Go approved source consumer failed: {} {}",
        String::from_utf8_lossy(&independent.stdout),
        String::from_utf8_lossy(&independent.stderr)
    );
    let observed = String::from_utf8_lossy(&independent.stdout);
    assert!(observed.contains("Scheme SDK -> authenticated CompileSource -> typed Go Bootstrap -> Rust final Policy denial"));
    eprintln!("{}", observed);
    let waiting = source.clone();
    let late = tokio::spawn(async move {
        rpc_fixture::unary::<_, pb::CompiledSource>(
            waiting,
            "source-token",
            COMPILE,
            pb::ProducerRequest {
                producer: "approved-AA".into(),
            },
        )
        .await
    });
    tokio::time::timeout(std::time::Duration::from_secs(3), started)
        .await
        .expect("paused call")
        .expect("entered");
    let rotated: pb::SourceRotationReceipt = rpc_fixture::unary(
        source,
        "source-token",
        "/weaver.gateway.v1.Gateway/RotateSourceAuthority",
        pb::SourceRotationRequest {
            operation_id: "rotate-during-compile".into(),
            expected_epoch: 0,
            next_certificate: pki.next.der.clone(),
            next_credential_sha256: hex::encode(Sha256::digest(b"next-token")),
        },
    )
    .await
    .expect("source rotation remains available during compilation");
    assert_eq!(
        rotated.outcome,
        pb::SourceRotationOutcome::SourceRotated as i32
    );
    release.send(()).expect("natural resume");
    let late = late.await.expect("compiler returned");
    assert_eq!(
        late.expect_err("retired source cannot receive late artifact")
            .code(),
        tonic::Code::PermissionDenied
    );
    let _ = stop.send(());
    server
        .await
        .expect("service task")
        .expect("natural shared drain");
    runtime.drain().await;
    assert_eq!(
        cleaned
            .await
            .expect("natural VM cleanup before acknowledgment"),
        3
    );
    assert_eq!(permits.available_permits(), capacity.get());
    worker.finish().await.expect("tracked worker joined");
    let mut ledger = weaver_ledger::Ledger::open(database).expect("recovered ledger");
    let next = weaver_server::source_certificate_identity(
        &pki.next.der,
        hex::encode(Sha256::digest(b"next-token")),
    )
    .expect("new identity");
    let current = ledger
        .with_authenticated_source(&next, |ledger| ledger.source_authority())
        .expect("current key floor")
        .expect("authority");
    assert_eq!(current.epoch, 1);
    assert!(
        ledger
            .provider_receipt("f", "infer")
            .expect("execution knowledge")
            .is_none()
    );
    assert!(matches!(
        ledger.enqueue_provider(&original.plans[0]),
        Err(weaver_contracts::Error::Denied)
    ));
    // Positive control uses the same committed task, body and provider profile.
    // It only admits a durable reservation; it never opens a provider transport.
    let allow = weaver_contracts::Publication {
        operation_id: "positive-control".into(),
        expected_revision: Some(0),
        fence: 2,
        policy: include_str!("../../../../prod/policies/provider/provider.cedar").into(),
        schema: original.publication.schema.clone(),
    };
    ledger
        .with_authenticated_source(&next, |ledger| {
            ledger.stage_authority(&allow)?;
            let receipt = ledger.publish_authority(&allow)?;
            assert_eq!(
                receipt.outcome,
                weaver_contracts::PublicationOutcome::Committed
            );
            Ok(())
        })
        .expect("current source publishes positive control");
    let mut allowed = original.plans[0].clone();
    allowed.revision = 1;
    allowed.fence = 2;
    ledger
        .enqueue_provider(&allowed)
        .expect("same task admitted under permit");
    ledger.close().expect("ledger cleanup");
    assert!(matches!(
        client.submit("approved-AA", &authority),
        Err(weaver_governance::CatalogError::Schedule(
            weaver_governance::SourceJobError::Closed
        ))
    ));
}
