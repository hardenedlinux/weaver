// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Default Go-to-Rust RPC boundary. Agent credentials cannot publish original authority.
use crate::grpc_listeners::{MeterMethod, MeterPaths, validate_listeners};
use crate::{
    ServerConfig,
    admission::Admission,
    connections, pb,
    rpc_security::{GrpcConfig, GrpcListeners, RpcRole},
    runtime::RuntimeOwner,
    source_owner::SourceOwner,
};
use sha2::{Digest, Sha256};
use std::future::Future;
use subtle::ConstantTimeEq;
use tokio::{net::TcpListener, sync::Semaphore};
use tonic::{Request, Status};
use weaver_broker::ProviderTransport;
use weaver_contracts::Error;

#[derive(Clone)]
pub(crate) struct Gateway {
    pub(crate) config: ServerConfig,
    pub(super) credential: [u8; 32],
    pub(super) ingress: Ingress,
    pub(super) peer: [u8; 32],
    pub(super) operation_peer: [u8; 32],
    pub(crate) routing: crate::source_owner::OperationResolver,
    pub(crate) transport: ProviderTransport,
    pub(crate) admission: Admission,
    pub(crate) runtime: RuntimeOwner,
    pub(crate) metering_enabled: bool,
    pub(crate) provider_oauth_enabled: bool,
    pub(crate) provider_oauth_relay: bool,
}
#[derive(Clone)]
pub(super) enum Ingress {
    Operation,
    Source(SourceOwner),
}
impl Ingress {
    fn role(&self) -> RpcRole {
        match self {
            Self::Operation => RpcRole::Operation,
            Self::Source(_) => RpcRole::Source,
        }
    }
    pub(super) fn source(&self) -> std::result::Result<&SourceOwner, Status> {
        match self {
            Self::Source(owner) => Ok(owner),
            Self::Operation => Err(Status::permission_denied(
                "source owner unavailable on operation ingress",
            )),
        }
    }
}
pub use crate::grpc_delivery::ResponseStream;

/// Serve the default authenticated RPC profile and acknowledge shutdown only after drain.
pub async fn serve_grpc(
    listeners: GrpcListeners,
    settings: GrpcConfig,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> weaver_contracts::Result<()> {
    serve_grpc_with_runtime(listeners, settings, RuntimeOwner::new(), shutdown).await
}
/// Embed approved owners in the same tracked runtime as source/operation RPC.
/// All attached owners must naturally drain before service completion.
pub async fn serve_grpc_with_runtime(
    listeners: GrpcListeners,
    settings: GrpcConfig,
    runtime: RuntimeOwner,
    shutdown: impl std::future::Future<Output = ()> + Send + 'static,
) -> weaver_contracts::Result<()> {
    let _lifetime = runtime.shutdown_guard();
    let result = match validate_listeners(&listeners, &settings) {
        Ok(()) => {
            let _ = rustls::crypto::ring::default_provider().install_default();
            serve_owned(listeners, settings, runtime.clone(), shutdown).await
        }
        Err(error) => Err(error),
    };
    runtime.drain().await;
    crate::shutdown::trace("tracked-owners-drained");
    result
}
async fn serve_owned(
    listeners: GrpcListeners,
    settings: GrpcConfig,
    runtime: RuntimeOwner,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> weaver_contracts::Result<()> {
    if runtime.session_wakeup().is_some() && settings.provider_oauth.is_some() {
        return Err(Error::Invalid(
            "automatic Session requires deployment provider credentials",
        ));
    }
    let admission = Admission::new(settings.owner.max_in_flight);
    let slot = admission
        .publication()
        .map_err(|_| Error::Conflict("source startup capacity"))?;
    let source_worker = match SourceOwner::start_reviewed(
        runtime.clone(),
        slot,
        settings.owner.database.clone(),
        settings.review_authority.clone(),
        settings.metering.clone(),
        settings.provider_oauth.clone(),
    )
    .await
    {
        Ok(owner) => owner,
        Err(error) => return Err(error),
    };
    let operation = Gateway::new(
        &settings,
        Ingress::Operation,
        admission.clone(),
        runtime.clone(),
        source_worker.client.operation_resolver(),
    );
    let source = Gateway::new(
        &settings,
        Ingress::Source(source_worker.client.clone()),
        admission,
        runtime.clone(),
        source_worker.client.operation_resolver(),
    );
    let session = operation.clone();
    let operation = serve_listener(
        listeners.operation,
        operation,
        settings.security.tls.clone(),
    );
    let source = serve_listener(listeners.source, source, settings.security.tls);
    tokio::pin!(operation, source, shutdown);
    let listeners = async {
        tokio::select! {
            result = &mut operation => { runtime.request_shutdown(); result.and(source.await) },
            result = &mut source => { runtime.request_shutdown(); result.and(operation.await) },
            _ = &mut shutdown => {
                crate::shutdown::trace("signal-observed");
                runtime.request_shutdown();
                crate::shutdown::trace("admission-closed");
                let (operation, source) = tokio::join!(operation, source);
                crate::shutdown::trace("listeners-drained");
                operation.and(source)
            },
        }
    };
    let (result, ()) = tokio::join!(listeners, session.run_session_workflow());
    let source_result = source_worker.finish().await;
    crate::shutdown::trace("source-owner-joined");
    result.and(source_result)
}

async fn serve_listener(
    listener: TcpListener,
    gateway: Gateway,
    tls: tonic::transport::ServerTlsConfig,
) -> weaver_contracts::Result<()> {
    let capacity = match gateway.ingress.role() {
        RpcRole::Operation => connections::MAX_CONNECTIONS,
        RpcRole::Source => connections::MAX_SOURCE_CONNECTIONS,
    };
    let close = gateway.runtime.clone();
    let authenticated = gateway.clone();
    let service = pb::gateway_server::GatewayServer::new(gateway)
        .max_decoding_message_size(2 * 1024 * 1024)
        .max_encoding_message_size(4 * 1024 * 1024);
    let service = tonic::service::interceptor::InterceptedService::new(
        service,
        move |request: Request<()>| {
            if request.extensions().get::<MeterMethod>().is_some() {
                authenticated.meter_identity(&request)?;
            } else {
                authenticated.authenticate(&request, authenticated.ingress.role())?;
            }
            Ok(request)
        },
    );
    let result = tonic::transport::Server::builder()
        .timeout(std::time::Duration::from_secs(10))
        .max_concurrent_streams(32)
        .concurrency_limit_per_connection(32)
        .http2_max_header_list_size(8192)
        .initial_stream_window_size(65536)
        .initial_connection_window_size(1048576)
        .tls_config(tls.timeout(std::time::Duration::from_secs(3)))
        .map_err(|_| Error::Invalid("gRPC TLS configuration"))?
        .add_service(MeterPaths(service))
        .serve_with_incoming_shutdown(
            connections::Incoming::new(listener, std::sync::Arc::new(Semaphore::new(capacity))),
            async move {
                close.cancellation().await;
            },
        )
        .await;
    result.map_err(|_| Error::Conflict("gRPC server failed"))
}
impl Gateway {
    fn bearer_hash<T>(request: &Request<T>) -> std::result::Result<[u8; 32], Status> {
        let metadata = request.metadata();
        if metadata.get_all("authorization").iter().count() != 1 {
            return Err(Status::unauthenticated("credential required"));
        }
        let token = metadata
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .filter(|v| !v.is_empty() && v.len() <= 256)
            .ok_or(Status::unauthenticated("credential required"))?;
        let actual: [u8; 32] = Sha256::digest(token.as_bytes()).into();
        Ok(actual)
    }
    pub(super) fn meter_identity<T>(
        &self,
        request: &Request<T>,
    ) -> std::result::Result<weaver_contracts::SourceIdentity, Status> {
        if self.runtime.closing() || self.ingress.role() != RpcRole::Source {
            return Err(Status::permission_denied("meter ingress required"));
        }
        let certificate=request.extensions().get::<tonic::transport::server::TlsConnectInfo<tonic::transport::server::TcpConnectInfo>>()
            .and_then(|tls|tls.peer_certs()).and_then(|chain|chain.first().cloned())
            .ok_or(Status::unauthenticated("meter certificate required"))?;
        crate::source_identity::certificate_identity(
            certificate.as_ref(),
            hex::encode(Self::bearer_hash(request)?),
        )
    }
    pub(super) fn source_identity<T>(
        &self,
        request: &Request<T>,
    ) -> std::result::Result<weaver_contracts::SourceIdentity, Status> {
        self.authenticate(request, RpcRole::Source)?;
        let certificates=request.extensions().get::<tonic::transport::server::TlsConnectInfo<tonic::transport::server::TcpConnectInfo>>()
            .and_then(|tls|tls.peer_certs()).ok_or(Status::unauthenticated("source certificate missing"))?;
        let certificate = certificates
            .first()
            .ok_or(Status::unauthenticated("source certificate missing"))?;
        crate::source_identity::certificate_identity(
            certificate.as_ref(),
            hex::encode(self.credential),
        )
    }
    fn new(
        settings: &GrpcConfig,
        ingress: Ingress,
        admission: Admission,
        runtime: RuntimeOwner,
        routing: crate::source_owner::OperationResolver,
    ) -> Self {
        let (peer, credential) = match ingress.role() {
            RpcRole::Operation => (settings.security.peer_sha256, settings.owner.token_sha256),
            RpcRole::Source => (
                settings.security.source_peer_sha256,
                settings.security.admin_sha256,
            ),
        };
        Self {
            routing,
            config: settings.owner.clone(),
            credential,
            ingress,
            peer,
            operation_peer: settings.security.peer_sha256,
            transport: settings.provider.clone(),
            admission,
            runtime,
            metering_enabled: settings.metering.is_some(),
            provider_oauth_enabled: settings.provider_oauth.is_some(),
            provider_oauth_relay: settings
                .provider_oauth
                .as_ref()
                .is_some_and(|config| config.relay_certificate_sha256.is_some()),
        }
    }
    pub(crate) fn authenticate<T>(
        &self,
        request: &Request<T>,
        role: RpcRole,
    ) -> std::result::Result<(), Status> {
        self.authenticate_request(request, role).inspect_err(|_| {
            self.runtime
                .telemetry()
                .record(weaver_telemetry::Signal::RpcAuthRejected);
        })
    }
    fn authenticate_request<T>(
        &self,
        request: &Request<T>,
        role: RpcRole,
    ) -> std::result::Result<(), Status> {
        if self.runtime.closing() {
            return Err(Status::unavailable("server closing"));
        }
        if self.ingress.role() != role {
            return Err(Status::permission_denied(
                "RPC method belongs to another ingress",
            ));
        }
        let peer=request.extensions().get::<tonic::transport::server::TlsConnectInfo<tonic::transport::server::TcpConnectInfo>>()
            .and_then(|tls|tls.peer_certs()).and_then(|certs|certs.first().map(|cert|Sha256::digest(cert.as_ref())));
        if peer.is_none_or(|digest| !bool::from(digest.as_slice().ct_eq(&self.peer))) {
            return Err(Status::unauthenticated("workload certificate rejected"));
        }
        let actual = Self::bearer_hash(request)?;
        if !bool::from(actual.ct_eq(&self.credential)) {
            return Err(Status::unauthenticated("credential rejected"));
        }
        Ok(())
    }
}
#[cfg(test)]
#[path = "../../tests/unit/grpc_ingress.rs"]
mod ingress_tests;
