// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Default Go-to-Rust RPC boundary. Agent credentials cannot publish original authority.
use crate::{
    ServerConfig,
    admission::Admission,
    connections,
    grpc_output::Output,
    pb,
    rpc_security::{GrpcConfig, GrpcListeners, RpcRole},
    runtime::RuntimeOwner,
    source_owner::SourceOwner,
};
use sha2::{Digest, Sha256};
use std::{
    future::Future,
    pin::Pin,
    task::{Context, Poll},
};
use subtle::ConstantTimeEq;
use tokio::{
    net::TcpListener,
    sync::{Semaphore, mpsc},
};
use tokio_stream::{Stream, wrappers::ReceiverStream};
use tokio_util::sync::CancellationToken;
use tonic::{Request, Response, Status};
use weaver_contracts::{Error, ProviderPlan, ProviderRoute, Task};
use weaver_execution::ProviderTransport;
use weaver_ledger::Ledger;
fn domain_view(v: weaver_contracts::DomainView) -> pb::DomainView {
    pb::DomainView {
        family: v.family,
        canonical_family: v.canonical_family,
        stamp: Some(pb::DomainStamp {
            task_key: v.stamp.task_key,
            origin: v.stamp.origin,
            budget_root: v.stamp.budget_root,
            history_root: v.stamp.history_root,
            budget_epoch: v.stamp.budget_epoch,
            history_epoch: v.stamp.history_epoch,
        }),
        budget_limit: v.budget_limit,
        held: v.held,
        history_count: v.history_count,
    }
}
#[derive(Clone)]
struct Gateway {
    config: ServerConfig,
    credential: [u8; 32],
    ingress: Ingress,
    peer: [u8; 32],
    operation_peer: [u8; 32],
    transport: ProviderTransport,
    admission: Admission,
    runtime: RuntimeOwner,
}
#[derive(Clone)]
enum Ingress {
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
    fn source(&self) -> std::result::Result<&SourceOwner, Status> {
        match self {
            Self::Source(owner) => Ok(owner),
            Self::Operation => Err(Status::permission_denied(
                "source owner unavailable on operation ingress",
            )),
        }
    }
}
/// Bounded RPC output whose destruction cancels its still-tracked native producer.
pub struct ResponseStream {
    receiver: ReceiverStream<std::result::Result<pb::ProviderFrame, Status>>,
    cancelled: CancellationToken,
    shutdown: Pin<Box<tokio_util::sync::WaitForCancellationFutureOwned>>,
}
impl Stream for ResponseStream {
    type Item = std::result::Result<pb::ProviderFrame, Status>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        if self.shutdown.as_mut().poll(cx).is_ready() {
            self.cancelled.cancel();
            self.receiver.close();
            return Poll::Ready(None);
        }
        Pin::new(&mut self.receiver).poll_next(cx)
    }
}
impl Drop for ResponseStream {
    fn drop(&mut self) {
        self.cancelled.cancel();
    }
}

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
    result
}
async fn serve_owned(
    listeners: GrpcListeners,
    settings: GrpcConfig,
    runtime: RuntimeOwner,
    shutdown: impl Future<Output = ()> + Send + 'static,
) -> weaver_contracts::Result<()> {
    let admission = Admission::new(settings.owner.max_in_flight);
    let slot = admission
        .publication()
        .map_err(|_| Error::Conflict("source startup capacity"))?;
    let source_worker = match SourceOwner::start_reviewed(
        runtime.clone(),
        slot,
        settings.owner.database.clone(),
        settings.review_authority.clone(),
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
    );
    let source = Gateway::new(
        &settings,
        Ingress::Source(source_worker.client.clone()),
        admission,
        runtime.clone(),
    );
    let operation = serve_listener(
        listeners.operation,
        operation,
        settings.security.tls.clone(),
    );
    let source = serve_listener(listeners.source, source, settings.security.tls);
    tokio::pin!(operation, source, shutdown);
    let result = tokio::select! {
        result = &mut operation => { runtime.request_shutdown(); result.and(source.await) },
        result = &mut source => { runtime.request_shutdown(); result.and(operation.await) },
        _ = &mut shutdown => {
            runtime.request_shutdown();
            let (operation, source) = tokio::join!(operation, source);
            operation.and(source)
        },
    };
    result.and(source_worker.finish().await)
}
fn validate_listeners(
    listeners: &GrpcListeners,
    settings: &GrpcConfig,
) -> weaver_contracts::Result<()> {
    settings.owner.validate()?;
    settings.review_authority.validate()?;
    let operation = listeners
        .operation
        .local_addr()
        .map_err(|e| Error::Storage(e.to_string()))?;
    let source = listeners
        .source
        .local_addr()
        .map_err(|e| Error::Storage(e.to_string()))?;
    if settings.security.admin_sha256 == [0; 32]
        || settings.security.peer_sha256 == [0; 32]
        || settings.security.source_peer_sha256 == [0; 32]
        || settings.security.source_peer_sha256 == settings.security.peer_sha256
        || settings.security.admin_sha256 == settings.owner.token_sha256
        || !operation.ip().is_loopback()
        || !source.ip().is_loopback()
        || operation == source
    {
        return Err(Error::Invalid("RPC identity or loopback profile"));
    }
    Ok(())
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
            authenticated.authenticate(&request, authenticated.ingress.role())?;
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
        .add_service(service)
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
    fn source_identity<T>(
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
    ) -> Self {
        let (peer, credential) = match ingress.role() {
            RpcRole::Operation => (settings.security.peer_sha256, settings.owner.token_sha256),
            RpcRole::Source => (
                settings.security.source_peer_sha256,
                settings.security.admin_sha256,
            ),
        };
        Self {
            config: settings.owner.clone(),
            credential,
            ingress,
            peer,
            operation_peer: settings.security.peer_sha256,
            transport: settings.provider.clone(),
            admission,
            runtime,
        }
    }
    fn authenticate<T>(
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
        if !bool::from(actual.ct_eq(&self.credential)) {
            return Err(Status::unauthenticated("credential rejected"));
        }
        Ok(())
    }
}
#[tonic::async_trait]
impl pb::gateway_server::Gateway for Gateway {
    async fn inspect_telemetry(
        &self,
        request: Request<pb::Empty>,
    ) -> std::result::Result<Response<pb::TelemetrySnapshot>, Status> {
        let caller = self.source_identity(&request)?;
        let _slot = self.admission.observation()?;
        self.ingress.source()?.authority(caller).await?;
        self.runtime
            .telemetry()
            .record(weaver_telemetry::Signal::SnapshotReads);
        Ok(Response::new(crate::telemetry::snapshot(
            self.runtime.telemetry(),
        )))
    }
    async fn register_original_task(
        &self,
        request: Request<pb::RegisterOriginalTaskRequest>,
    ) -> std::result::Result<Response<pb::TaskAdmissionReceipt>, Status> {
        let caller = self.source_identity(&request)?;
        let r = request.into_inner();
        let task = r
            .task
            .ok_or(Status::invalid_argument("original task required"))?;
        let d = r
            .domains
            .ok_or(Status::invalid_argument("original binding required"))?;
        let a = r.admission.ok_or(Status::invalid_argument(
            "stable source task identity required",
        ))?;
        let receipt = self
            .ingress
            .source()?
            .original(
                caller,
                task_contract(task),
                weaver_contracts::DomainBinding {
                    origin: d.origin,
                    budget: d.budget,
                    history: d.history,
                    budget_limit: d.budget_limit,
                },
                weaver_contracts::TaskAdmission {
                    task_key: a.task_key,
                    operation_id: a.operation_id,
                    expected_source_epoch: a.expected_source_epoch,
                },
                r.publication.map(|p| weaver_contracts::PublicationKey {
                    operation_id: p.operation_id,
                    digest: p.digest,
                }),
            )
            .await?;
        Ok(Response::new(pb::TaskAdmissionReceipt {
            operation_id: receipt.operation_id,
            digest: receipt.digest,
            task_key: receipt.task_key,
            family: receipt.family,
            origin: receipt.origin,
            source_epoch: receipt.source_epoch,
        }))
    }
    async fn register_domain_task(
        &self,
        request: Request<pb::RegisterDomainTaskRequest>,
    ) -> std::result::Result<Response<pb::Empty>, Status> {
        let caller = self.source_identity(&request)?;
        let body = request.into_inner();
        let task = body.task.ok_or(Status::invalid_argument("task missing"))?;
        let domains = body
            .domains
            .ok_or(Status::invalid_argument("original domains missing"))?;
        self.ingress
            .source()?
            .register_domain(
                caller,
                task_contract(task),
                weaver_contracts::DomainBinding {
                    origin: domains.origin,
                    budget: domains.budget,
                    history: domains.history,
                    budget_limit: domains.budget_limit,
                },
                body.publication
                    .map(|key| weaver_contracts::PublicationKey {
                        operation_id: key.operation_id,
                        digest: key.digest,
                    }),
            )
            .await?;
        Ok(Response::new(pb::Empty {}))
    }
    async fn register_family_alias(
        &self,
        request: Request<pb::FamilyAliasRequest>,
    ) -> std::result::Result<Response<pb::DomainView>, Status> {
        let caller = self.source_identity(&request)?;
        let body = request.into_inner();
        let view = self
            .ingress
            .source()?
            .alias(caller, body.family, body.origin)
            .await?;
        Ok(Response::new(domain_view(view)))
    }
    async fn inspect_execution_domains(
        &self,
        request: Request<pb::OperationKey>,
    ) -> std::result::Result<Response<pb::DomainView>, Status> {
        let caller = self.source_identity(&request)?;
        let view = self
            .ingress
            .source()?
            .domains(caller, request.into_inner().family)
            .await?;
        Ok(Response::new(domain_view(view)))
    }
    async fn migrate_execution_domains(
        &self,
        request: Request<pb::DomainMigration>,
    ) -> std::result::Result<Response<pb::DomainMigrationReceipt>, Status> {
        let caller = self.source_identity(&request)?;
        let c = request.into_inner();
        let r = self
            .ingress
            .source()?
            .migrate(
                caller,
                weaver_contracts::DomainMigration {
                    operation_id: c.operation_id,
                    budget_from: c.budget_from,
                    budget_to: c.budget_to,
                    history_from: c.history_from,
                    history_to: c.history_to,
                    budget_from_epoch: c.budget_from_epoch,
                    budget_to_epoch: c.budget_to_epoch,
                    history_from_epoch: c.history_from_epoch,
                    history_to_epoch: c.history_to_epoch,
                },
            )
            .await?;
        Ok(Response::new(pb::DomainMigrationReceipt {
            operation_id: r.operation_id,
            digest: r.digest,
            committed: r.committed,
            budget_root: r.budget_root,
            history_root: r.history_root,
            budget_epoch: r.budget_epoch,
            history_epoch: r.history_epoch,
        }))
    }
    type ExecuteProviderStream = ResponseStream;
    async fn compile_source(
        &self,
        request: Request<pb::ProducerRequest>,
    ) -> std::result::Result<Response<pb::CompiledSource>, Status> {
        let caller = self.source_identity(&request)?;
        let producer = request.into_inner().producer;
        weaver_contracts::identifier(&producer)
            .map_err(|_| Status::invalid_argument("producer name invalid"))?;
        let source = self.ingress.source()?;
        let before = source.authority(caller.clone()).await?;
        let client = self
            .runtime
            .producers()
            .map_err(|_| Status::failed_precondition("approved producer catalog unavailable"))?;
        let job = client
            .submit(&producer, &before)
            .map_err(compilation_status)?;
        let bound = tokio::select! {
            result=job=>result.map_err(|error|{
                self.runtime.telemetry().record(weaver_telemetry::Signal::CompilationFailed);
                compilation_status(error.into())
            })?,
            _=self.runtime.cancellation()=>return Err(Status::unavailable("source compilation closed")),
        };
        // No source SQL lane is retained while foreign code runs. Re-observe the
        // actual caller after completion; a captured old observation is not use.
        let after = source.authority(caller).await?;
        if after != before {
            return Err(Status::permission_denied(
                "source authority changed during compilation",
            ));
        }
        if self.runtime.closing() {
            return Err(Status::unavailable("source compilation closed"));
        }
        let reply = pb::CompiledSource {
            producer,
            authority: Some(crate::source_identity::view(after)?),
            artifact: Some(crate::source_artifact::artifact(&bound)),
        };
        if prost::Message::encoded_len(&reply) > 4 * 1024 * 1024 {
            return Err(Status::resource_exhausted(
                "compiled source exceeds RPC response bound",
            ));
        }
        self.runtime
            .telemetry()
            .record(weaver_telemetry::Signal::CompilationSucceeded);
        Ok(Response::new(reply))
    }
    async fn execute_provider(
        &self,
        request: Request<pb::ProviderRequest>,
    ) -> std::result::Result<Response<Self::ExecuteProviderStream>, Status> {
        self.authenticate(&request, RpcRole::Operation)?;
        let slot = self.admission.execution()?;
        let request = request.into_inner();
        let arrow = match pb::Encoding::try_from(request.encoding) {
            Ok(pb::Encoding::Protobuf) => false,
            Ok(pb::Encoding::ArrowIpc) if cfg!(feature = "arrow") => true,
            _ => return Err(Status::unimplemented("response encoding unavailable")),
        };
        if request.batch_rows == 0 || request.batch_rows > 32 || (!arrow && request.batch_rows != 1)
        {
            return Err(Status::invalid_argument("response batch bound"));
        }
        let plan = plan(
            request
                .plan
                .ok_or(Status::invalid_argument("plan missing"))?,
        )?;
        let (sender, receiver) = mpsc::channel(2);
        let cancelled = CancellationToken::new();
        let mut output = Output {
            telemetry: self.runtime.telemetry().clone(),
            sender: sender.clone(),
            cancelled: cancelled.clone(),
            shutdown: CancellationToken::new(),
            runtime: tokio::runtime::Handle::current(),
        };
        let config = self.config.clone();
        let transport = self.transport.clone();
        let job = self
            .runtime
            .spawn_blocking(slot, move |shutdown| {
                output.shutdown = shutdown;
                let result = (|| {
                    let mut ledger = Ledger::open(&config.database)?;
                    #[cfg(all(test, unix))]
                    crate::provider_commit_tests::attach(&mut ledger);
                    ledger.require_principal(&config.principal, &plan.family)?;
                    weaver_execution::execute_provider(
                        &mut ledger,
                        weaver_execution::ProviderExecution {
                            plan: &plan,
                            transport: &transport,
                            format: if arrow { "arrow" } else { "protobuf" },
                            batch_rows: request.batch_rows as usize,
                        },
                        &mut output,
                    )
                })();
                output.telemetry.record(if result.is_ok() {
                    weaver_telemetry::Signal::ProviderCompleted
                } else {
                    weaver_telemetry::Signal::ProviderFailed
                });
                if result.is_err() {
                    let _ = sender.try_send(Err(Status::failed_precondition(
                        "provider execution not completed; inspect original operation",
                    )));
                }
                result
            })
            .map_err(|_| Status::unavailable("native admission closed"))?;
        self.runtime
            .telemetry()
            .record(weaver_telemetry::Signal::ProviderAdmitted);
        drop(job); // The runtime tracker, not the disconnected caller, owns completion.
        Ok(Response::new(ResponseStream {
            receiver: ReceiverStream::new(receiver),
            cancelled,
            shutdown: Box::pin(self.runtime.cancellation()),
        }))
    }
    async fn inspect(
        &self,
        request: Request<pb::OperationKey>,
    ) -> std::result::Result<Response<pb::ProviderReceipt>, Status> {
        self.authenticate(&request, RpcRole::Operation)?;
        let slot = self.admission.observation()?;
        let key = request.into_inner();
        let config = self.config.clone();
        let job = self
            .runtime
            .spawn_blocking(slot, move |_| {
                let ledger = Ledger::open(&config.database)?;
                ledger.require_principal(&config.principal, &key.family)?;
                ledger
                    .provider_receipt(&key.family, &key.node)?
                    .ok_or(Error::Conflict("operation missing"))
            })
            .map_err(status)?;
        let receipt = job
            .await
            .map_err(|_| Status::internal("native worker failed"))?
            .map_err(status)?;
        Ok(Response::new(pb::ProviderReceipt {
            family: receipt.family,
            node: receipt.node,
            digest: receipt.digest,
            state: receipt.state.as_str().into(),
            target: receipt.target.unwrap_or_default(),
            reserved: receipt.reserved,
            held: receipt.held,
            events: receipt.events,
        }))
    }
    async fn register_task(
        &self,
        request: Request<pb::RegisterTaskRequest>,
    ) -> std::result::Result<Response<pb::Empty>, Status> {
        let caller = self.source_identity(&request)?;
        let task = request
            .into_inner()
            .task
            .ok_or(Status::invalid_argument("task missing"))?;
        self.ingress
            .source()?
            .register(caller, task_contract(task), None)
            .await?;
        Ok(Response::new(pb::Empty {}))
    }
    async fn register_published_task(
        &self,
        request: Request<pb::RegisterPublishedTaskRequest>,
    ) -> std::result::Result<Response<pb::Empty>, Status> {
        let caller = self.source_identity(&request)?;
        let registration = request.into_inner();
        let task = registration
            .task
            .ok_or(Status::invalid_argument("task missing"))?;
        let key = registration
            .publication
            .ok_or(Status::invalid_argument("original publication missing"))?;
        self.ingress
            .source()?
            .register(
                caller,
                task_contract(task),
                Some(weaver_contracts::PublicationKey {
                    operation_id: key.operation_id,
                    digest: key.digest,
                }),
            )
            .await?;
        Ok(Response::new(pb::Empty {}))
    }
    async fn stage_authority(
        &self,
        request: Request<pb::PublishRequest>,
    ) -> std::result::Result<Response<pb::PublicationKey>, Status> {
        let caller = self.source_identity(&request)?;
        let change = request.into_inner();
        let key = self
            .ingress
            .source()?
            .stage(
                caller,
                weaver_contracts::Publication {
                    operation_id: change.operation_id,
                    expected_revision: change.expected_revision,
                    policy: change.policy,
                    schema: change.schema,
                    fence: change.fence,
                },
            )
            .await?;
        Ok(Response::new(pb::PublicationKey {
            operation_id: key.operation_id,
            digest: key.digest,
        }))
    }
    async fn publish_authority(
        &self,
        request: Request<pb::PublishRequest>,
    ) -> std::result::Result<Response<pb::PublicationReceipt>, Status> {
        let caller = self.source_identity(&request)?;
        let change = request.into_inner();
        let receipt = self
            .ingress
            .source()?
            .publish(
                caller,
                weaver_contracts::Publication {
                    operation_id: change.operation_id,
                    expected_revision: change.expected_revision,
                    policy: change.policy,
                    schema: change.schema,
                    fence: change.fence,
                },
            )
            .await?;
        Ok(Response::new(publication_receipt(receipt)))
    }
    async fn stage_reviewed_authority(
        &self,
        request: Request<pb::PublishRequest>,
    ) -> std::result::Result<Response<pb::PublicationKey>, Status> {
        let caller = self.source_identity(&request)?;
        let p = request.into_inner();
        let key = self
            .ingress
            .source()?
            .stage_reviewed(
                caller,
                weaver_contracts::Publication {
                    operation_id: p.operation_id,
                    expected_revision: p.expected_revision,
                    fence: p.fence,
                    policy: p.policy,
                    schema: p.schema,
                },
            )
            .await?;
        Ok(Response::new(pb::PublicationKey {
            operation_id: key.operation_id,
            digest: key.digest,
        }))
    }
    async fn inspect_publication_review(
        &self,
        request: Request<pb::PublicationKey>,
    ) -> std::result::Result<Response<pb::PublicationReviewContext>, Status> {
        let caller = self.source_identity(&request)?;
        let key = request.into_inner();
        let context = self
            .ingress
            .source()?
            .review_context(
                caller,
                weaver_contracts::PublicationKey {
                    operation_id: key.operation_id,
                    digest: key.digest,
                },
            )
            .await?;
        Ok(Response::new(crate::review_wire::context(context)?))
    }
    async fn register_publication_review(
        &self,
        request: Request<pb::DeltaReview>,
    ) -> std::result::Result<Response<pb::ReviewRegistrationReceipt>, Status> {
        let caller = self.source_identity(&request)?;
        let evidence = crate::review_wire::evidence(request.into_inner())?;
        let key = evidence.review.publication.clone();
        let digest = self
            .ingress
            .source()?
            .register_review(caller, evidence)
            .await?;
        Ok(Response::new(pb::ReviewRegistrationReceipt {
            publication: Some(pb::PublicationKey {
                operation_id: key.operation_id,
                digest: key.digest,
            }),
            review_digest: digest,
        }))
    }
    async fn inspect_publication(
        &self,
        request: Request<pb::PublicationKey>,
    ) -> std::result::Result<Response<pb::PublicationReceipt>, Status> {
        let caller = self.source_identity(&request)?;
        let key = request.into_inner();
        let receipt = self
            .ingress
            .source()?
            .inspect(
                caller,
                weaver_contracts::PublicationKey {
                    operation_id: key.operation_id,
                    digest: key.digest,
                },
            )
            .await?
            .ok_or(Status::not_found(
                "publication decision not observed; absence is not abort",
            ))?;
        Ok(Response::new(publication_receipt(receipt)))
    }
    async fn inspect_source_authority(
        &self,
        request: Request<pb::Empty>,
    ) -> std::result::Result<Response<pb::SourceAuthorityView>, Status> {
        let caller = self.source_identity(&request)?;
        let authority = self.ingress.source()?.authority(caller).await?;
        Ok(Response::new(crate::source_identity::view(authority)?))
    }
    async fn rotate_source_authority(
        &self,
        request: Request<pb::SourceRotationRequest>,
    ) -> std::result::Result<Response<pb::SourceRotationReceipt>, Status> {
        let caller = self.source_identity(&request)?;
        let change = request.into_inner();
        let next = crate::source_identity::certificate_identity(
            &change.next_certificate,
            change.next_credential_sha256,
        )?;
        if next.certificate_sha256 == hex::encode(self.operation_peer)
            || next.credential_sha256 == hex::encode(self.config.token_sha256)
        {
            return Err(Status::invalid_argument(
                "source successor aliases operation identity",
            ));
        }
        let receipt = self
            .ingress
            .source()?
            .rotate(
                caller,
                weaver_contracts::SourceRotation {
                    operation_id: change.operation_id,
                    expected_epoch: change.expected_epoch,
                    next,
                },
            )
            .await?;
        Ok(Response::new(pb::SourceRotationReceipt {
            operation_id: receipt.operation_id,
            digest: receipt.digest,
            outcome: match receipt.outcome {
                weaver_contracts::SourceRotationOutcome::Committed => {
                    pb::SourceRotationOutcome::SourceRotated as i32
                }
                weaver_contracts::SourceRotationOutcome::Rejected => {
                    pb::SourceRotationOutcome::SourceRotationRejected as i32
                }
            },
            authority: Some(crate::source_identity::view(receipt.authority)?),
        }))
    }
}
fn compilation_status(error: weaver_governance::CatalogError) -> Status {
    use weaver_governance::{CatalogError, SourceJobError};
    match error {
        CatalogError::Denied => Status::permission_denied("producer/source binding rejected"),
        CatalogError::Invalid => Status::failed_precondition("producer catalog invalid"),
        CatalogError::Schedule(SourceJobError::Busy) => {
            Status::resource_exhausted("source compilation lane full")
        }
        CatalogError::Schedule(SourceJobError::Source(_)) => {
            Status::failed_precondition("source compiler rejected original")
        }
        CatalogError::Schedule(_) => Status::unavailable("source compiler unavailable"),
    }
}
fn publication_receipt(receipt: weaver_contracts::PublicationReceipt) -> pb::PublicationReceipt {
    pb::PublicationReceipt {
        operation_id: receipt.operation_id,
        digest: receipt.digest,
        outcome: match receipt.outcome {
            weaver_contracts::PublicationOutcome::Committed => {
                pb::PublicationOutcome::Committed as i32
            }
            weaver_contracts::PublicationOutcome::Rejected => {
                pb::PublicationOutcome::Rejected as i32
            }
        },
        revision: receipt.revision,
        fence: receipt.fence,
    }
}
fn status(_: Error) -> Status {
    Status::failed_precondition("native authority or state rejected")
}
fn plan(p: pb::ProviderPlan) -> std::result::Result<ProviderPlan, Status> {
    let body = String::from_utf8(p.body)
        .map_err(|_| Status::invalid_argument("UTF-8 provider body required"))?;
    let plan = ProviderPlan {
        family: p.family,
        node: p.node,
        profile: p.profile,
        profile_commitment: p.profile_commitment,
        model: p.model,
        body,
        routes: p
            .routes
            .into_iter()
            .map(|r| ProviderRoute {
                target: r.target,
                endpoint: r.endpoint,
            })
            .collect(),
        ceiling: p.ceiling,
        revision: p.revision,
        fence: p.fence,
    };
    plan.validate().map_err(status)?;
    Ok(plan)
}
fn task_contract(t: pb::Task) -> Task {
    Task {
        provider_profile: t
            .provider_profile
            .map(|profile| weaver_contracts::ProviderProfile {
                id: profile.id,
                protocol: profile.protocol,
                max_output_tokens: profile.max_output_tokens,
                max_messages: profile.max_messages,
                max_body_bytes: profile.max_body_bytes,
            }),
        family: t.family,
        principal: t.principal,
        profile: t.profile,
        nodes: t.nodes,
        targets: t.targets,
        endpoints: t.endpoints.into_iter().collect(),
        body_digests: t.body_digests.into_iter().collect(),
        node_cost_bounds: t.node_cost_bounds.into_iter().collect(),
        stream_contracts: t.stream_contracts.into_iter().collect(),
        models: t.models,
        budget: t.budget,
    }
}

#[cfg(test)]
#[path = "../tests/unit/grpc_ingress.rs"]
mod ingress_tests;
