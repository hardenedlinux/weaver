use super::validate_listeners;
use crate::{GrpcConfig, GrpcListeners, RpcSecurity, ServerConfig};
use tonic::transport::ServerTlsConfig;

#[tokio::test]
async fn aliased_or_empty_source_identity_is_rejected_before_serving() {
    let listeners = GrpcListeners {
        operation: tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("operation"),
        source: tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("source"),
    };
    let mut settings = GrpcConfig {
        owner: ServerConfig {
            database: "unused.db".into(),
            principal: "alice".into(),
            token_sha256: [1; 32],
            max_in_flight: 16,
        },
        security: RpcSecurity {
            tls: ServerTlsConfig::new(),
            peer_sha256: [2; 32],
            source_peer_sha256: [3; 32],
            admin_sha256: [4; 32],
        },
        provider: weaver_execution::ProviderTransport::new(
            Default::default(),
            None,
            tokio::runtime::Handle::current(),
        )
        .expect("configuration"),
    };
    assert!(validate_listeners(&listeners, &settings).is_ok());
    settings.security.source_peer_sha256 = [2; 32];
    assert!(validate_listeners(&listeners, &settings).is_err());
    settings.security.source_peer_sha256 = [0; 32];
    assert!(validate_listeners(&listeners, &settings).is_err());
    settings.security.source_peer_sha256 = [3; 32];
    settings.security.admin_sha256 = [1; 32];
    assert!(validate_listeners(&listeners, &settings).is_err());

    // An invalid embedding configuration must still drain an attached compiler;
    // returning before shared cleanup would strand the tracked Scheme owner.
    let runtime = crate::ServiceRuntime::new();
    let slots = std::sync::Arc::new(tokio::sync::Semaphore::new(2));
    let slot = std::sync::Arc::new(slots.clone().try_acquire_owned().expect("host slot"));
    let (done, mut destroyed) = tokio::sync::oneshot::channel::<()>();
    let worker = runtime
        .start_governance(
            slot,
            std::thread::available_parallelism().expect("host budget"),
            move || {
                Ok(move |source: &weaver_governance::OwnedSource| {
                    let _keep = &done;
                    weaver_governance::OwnedSource::from_source(source.data().clone())
                })
            },
        )
        .await
        .expect("attached compiler");
    assert!(
        crate::serve_grpc_with_runtime(listeners, settings, runtime.clone(), async {})
            .await
            .is_err()
    );
    assert!(runtime.closing());
    assert!(matches!(
        destroyed.try_recv(),
        Err(tokio::sync::oneshot::error::TryRecvError::Closed)
    ));
    assert_eq!(slots.available_permits(), 2);
    worker.finish().await.expect("compiler joined");
}
