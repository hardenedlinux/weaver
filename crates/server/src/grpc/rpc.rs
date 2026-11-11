// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed RPC methods for the authenticated Gateway service.
use super::service::{Gateway, ResponseStream};
use crate::{
    grpc_contracts::{compilation_status, domain_view, publication_receipt, status, task_contract},
    pb,
    rpc_security::RpcRole,
};
use tonic::{Request, Response, Status};
use weaver_contracts::Error;
use weaver_ledger::Ledger;

#[tonic::async_trait]
impl pb::gateway_server::Gateway for Gateway {
    async fn inspect_hard_fact(
        &self,
        request: Request<pb::Empty>,
    ) -> Result<Response<pb::HardFactFeedState>, Status> {
        let caller = self.source_identity(&request)?;
        let state = self.ingress.source()?.inspect_fact(caller).await?;
        Ok(Response::new(Self::fact_feed_state(state)))
    }

    async fn stage_hard_fact(
        &self,
        request: Request<pb::HardFactIntent>,
    ) -> Result<Response<pb::HardFactBarrier>, Status> {
        let caller = self.source_identity(&request)?;
        self.stage_fact_request(self.ingress.source()?, caller, request.into_inner())
            .await
    }

    async fn resolve_hard_fact(
        &self,
        request: Request<pb::HardFactBarrier>,
    ) -> Result<Response<pb::FactBarrierResolution>, Status> {
        let caller = self.source_identity(&request)?;
        self.resolve_fact_request(self.ingress.source()?, caller, request.into_inner())
            .await
    }

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
    async fn rotate_meter_credential(
        &self,
        request: Request<pb::MeterCredentialRotation>,
    ) -> std::result::Result<Response<pb::MeterCredentialEpoch>, Status> {
        let caller = self.source_identity(&request)?;
        let r = request.into_inner();
        let next =
            crate::source_identity::certificate_identity(&r.certificate, r.credential_sha256)?;
        if next.certificate_sha256 == hex::encode(self.peer)
            || next.certificate_sha256 == hex::encode(self.operation_peer)
            || next.credential_sha256 == hex::encode(self.credential)
            || next.credential_sha256 == hex::encode(self.config.token_sha256)
        {
            return Err(Status::permission_denied(
                "meter credential aliases another role",
            ));
        }
        let epoch = self
            .ingress
            .source()?
            .rotate_meter(caller, r.tenant, r.issuer, r.expected_epoch, next)
            .await?;
        Ok(Response::new(pb::MeterCredentialEpoch { epoch }))
    }
    async fn inspect_terminal_usage(
        &self,
        request: Request<pb::OperationKey>,
    ) -> std::result::Result<Response<pb::MeteringReceipt>, Status> {
        let caller = self.meter_identity(&request)?;
        let key = request.into_inner();
        let r = self
            .ingress
            .source()?
            .terminal_usage(caller, key.family, key.node)
            .await?;
        Ok(Response::new(pb::MeteringReceipt {
            audience: r.audience,
            tenant: r.tenant,
            issuer: r.issuer,
            application: r.application,
            family: r.family,
            node: r.node,
            origin: r.origin,
            plan_digest: r.plan_digest,
            target: r.target,
            formula_digest: r.formula_digest,
            terminal_digest: r.terminal_digest,
            tokens: r.tokens.to_vec(),
            signature: r.signature,
        }))
    }
    async fn apply_metering(
        &self,
        request: Request<pb::MeteringReceipt>,
    ) -> std::result::Result<Response<pb::MeteringApplication>, Status> {
        let caller = self.meter_identity(&request)?;
        if !self.metering_enabled {
            return Err(Status::failed_precondition(
                "metering deployment unavailable",
            ));
        }
        let r = request.into_inner();
        let result = self
            .ingress
            .source()?
            .apply_metering(
                caller,
                weaver_contracts::MeteringReceipt {
                    audience: r.audience,
                    tenant: r.tenant,
                    issuer: r.issuer,
                    application: r.application,
                    family: r.family,
                    node: r.node,
                    origin: r.origin,
                    plan_digest: r.plan_digest,
                    target: r.target,
                    formula_digest: r.formula_digest,
                    terminal_digest: r.terminal_digest,
                    tokens: r
                        .tokens
                        .try_into()
                        .map_err(|_| Status::invalid_argument("metering token categories"))?,
                    signature: r.signature,
                },
            )
            .await?;
        Ok(Response::new(pb::MeteringApplication {
            application: result.application,
            charged: result.charged,
            released: result.released,
        }))
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
    async fn compose_source(
        &self,
        request: Request<pb::SourceCompositionRequest>,
    ) -> std::result::Result<Response<pb::SourceCompositionReply>, Status> {
        let caller = self.source_identity(&request)?;
        let input = request.into_inner();
        let source = self.ingress.source()?;
        let before = source.authority(caller.clone()).await?;
        let use_catalog = input.use_catalog;
        let snapshot = if use_catalog {
            source.provider_catalog(caller.clone()).await?
        } else {
            None
        };
        let version = snapshot
            .as_ref()
            .map(|(version, _)| version.as_str())
            .unwrap_or("")
            .to_owned();
        if input.expected_catalog_version != version {
            return Err(Status::failed_precondition(
                "composition catalog version changed",
            ));
        }
        let output = crate::source_composition::compose(
            &self.runtime,
            input,
            snapshot.as_ref().map(|(_, bytes)| bytes.as_slice()),
        )
        .await?;
        if source.authority(caller.clone()).await? != before || self.runtime.closing() {
            return Err(Status::permission_denied(
                "source authority changed during composition",
            ));
        }
        if use_catalog
            && source
                .provider_catalog(caller)
                .await?
                .as_ref()
                .map(|(version, _)| version.as_str())
                .unwrap_or("")
                != version
        {
            return Err(Status::failed_precondition(
                "composition catalog version changed",
            ));
        }
        Ok(Response::new(pb::SourceCompositionReply {
            artifact: Some(crate::source_artifact::artifact_data(output.data())),
            catalog_version: version,
        }))
    }
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
        let lifecycle = self.runtime.single_provider();
        let _prepare = match lifecycle {
            Some(lifecycle) => Some(
                lifecycle
                    .prepare
                    .try_lock()
                    .map_err(|_| Status::resource_exhausted("provider preparation in progress"))?,
            ),
            None => None,
        };
        if let Some(prepared) = lifecycle.and_then(|lifecycle| lifecycle.ready.get()) {
            if prepared.producer != producer || prepared.authority != before {
                return Err(Status::permission_denied(
                    "prepared provider binding changed",
                ));
            }
            if self.runtime.closing() {
                return Err(Status::unavailable("source compilation closed"));
            }
            return Ok(Response::new(prepared.reply()));
        }
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
        crate::source_composition::validate_transport(bound.source())?;
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
            authority: Some(crate::source_identity::view(after.clone())?),
            artifact: Some(crate::source_artifact::artifact(&bound)),
        };
        if prost::Message::encoded_len(&reply) > 4 * 1024 * 1024 {
            return Err(Status::resource_exhausted(
                "compiled source exceeds RPC response bound",
            ));
        }
        if let Some(lifecycle) = lifecycle {
            let prepared = crate::single_provider::Prepared::new(
                &reply,
                after,
                bound,
                self.runtime.fact_feed(),
            )
            .map_err(status)?;
            lifecycle
                .ready
                .set(prepared)
                .map_err(|_| Status::internal("provider preparation already sealed"))?;
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
        self.execute_provider_stream(request).await
    }
    async fn inspect(
        &self,
        request: Request<pb::OperationKey>,
    ) -> std::result::Result<Response<pb::ProviderReceipt>, Status> {
        self.authenticate(&request, RpcRole::Operation)?;
        let oauth = crate::provider_oauth::observe(
            self.provider_oauth_enabled,
            self.provider_oauth_relay,
            &request,
        )?;
        let slot = self.admission.observation()?;
        let key = request.into_inner();
        let config = self.config.clone();
        let job = self
            .runtime
            .spawn_blocking(slot, move |_| {
                let mut ledger = Ledger::open(&config.database)?;
                ledger.require_principal(&config.principal, &key.family)?;
                let receipt = match oauth.as_ref() {
                    Some(evidence) => {
                        ledger.inspect_provider_oauth(&key.family, &key.node, Some(evidence))
                    }
                    None => ledger.provider_receipt(&key.family, &key.node),
                }?;
                receipt.ok_or(Error::Conflict("operation missing"))
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
    async fn change_provider_o_auth(
        &self,
        request: Request<pb::ProviderOAuthChange>,
    ) -> std::result::Result<Response<pb::Empty>, Status> {
        let caller = self.source_identity(&request)?;
        let action = request
            .into_inner()
            .action
            .ok_or(Status::invalid_argument("provider OAuth change required"))?;
        self.ingress
            .source()?
            .change_provider_oauth(caller, action)
            .await?;
        Ok(Response::new(pb::Empty {}))
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
        if let Some(wire) = registration.source_scope {
            if registration.task.is_some()
                || wire.use_catalog
                || !wire.expected_catalog_version.is_empty()
            {
                return Err(Status::invalid_argument("source registration shape"));
            }
            let key = registration
                .publication
                .ok_or(Status::invalid_argument("original publication missing"))?;
            let input = crate::source_composition::decode(wire)?;
            if input.source.publication.operation_id != key.operation_id
                || input.source.publication.digest().map_err(status)? != key.digest
            {
                return Err(Status::invalid_argument("source publication mismatch"));
            }
            let selected =
                crate::source_composition::compose_typed(&self.runtime, input.clone(), None)
                    .await?;
            if input.routing.is_empty() {
                for plan in selected.plans() {
                    self.ingress
                        .source()?
                        .register_operation_source(
                            caller.clone(),
                            weaver_contracts::ProviderOperationScope::Fixed {
                                task: selected.task().clone(),
                                plan: plan.clone(),
                                publication: selected.publication().clone(),
                            },
                        )
                        .await?;
                }
            } else {
                if input.source.tasks.len() != 1
                    || !input.source.plans.is_empty()
                    || input.routing.len() != 1
                    || input.source.governance.family != input.source.tasks[0].family
                    || input.source.governance.open_nodes != input.source.tasks[0].nodes
                    || !input.source.governance.workflow_edges.is_empty()
                    || !input.source.governance.workflow_selectors.is_empty()
                    || self.runtime.single_provider().is_some()
                {
                    return Err(Status::invalid_argument("deferred source scope mismatch"));
                }
                let scope = weaver_contracts::ProviderRoutingScope {
                    task: input
                        .source
                        .tasks
                        .into_iter()
                        .next()
                        .ok_or(Status::invalid_argument("source task missing"))?,
                    selection_schema: input.source.governance.schema,
                    selection: input
                        .routing
                        .into_iter()
                        .next()
                        .ok_or(Status::invalid_argument("source selection missing"))?,
                    publication: input.source.publication,
                };
                self.ingress
                    .source()?
                    .register_operation_source(
                        caller,
                        weaver_contracts::ProviderOperationScope::Catalog { routing: scope },
                    )
                    .await?;
            }
            return Ok(Response::new(pb::Empty {}));
        }
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
        let source = self.ingress.source()?;
        let receipt = source
            .publish(
                caller.clone(),
                weaver_contracts::Publication {
                    operation_id: change.operation_id,
                    expected_revision: change.expected_revision,
                    policy: change.policy,
                    schema: change.schema,
                    fence: change.fence,
                },
            )
            .await?;
        self.retire_prepared_provider(source, caller, &receipt)
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
        let source = self.ingress.source()?;
        let receipt = source
            .inspect(
                caller.clone(),
                weaver_contracts::PublicationKey {
                    operation_id: key.operation_id,
                    digest: key.digest,
                },
            )
            .await?
            .ok_or(Status::not_found(
                "publication decision not observed; absence is not abort",
            ))?;
        self.retire_prepared_provider(source, caller, &receipt)
            .await?;
        Ok(Response::new(publication_receipt(receipt)))
    }
    async fn inspect_provider_catalog(
        &self,
        request: Request<pb::Empty>,
    ) -> std::result::Result<Response<pb::ProviderCatalogSnapshot>, Status> {
        let caller = self.source_identity(&request)?;
        let snapshot = self.ingress.source()?.provider_catalog(caller).await?;
        let Some((version, record)) = snapshot else {
            return Ok(Response::new(pb::ProviderCatalogSnapshot::default()));
        };
        Ok(Response::new(pb::ProviderCatalogSnapshot {
            version,
            record,
        }))
    }
    async fn publish_provider_catalog(
        &self,
        request: Request<pb::ProviderCatalogChange>,
    ) -> std::result::Result<Response<pb::ProviderCatalogSnapshot>, Status> {
        let caller = self.source_identity(&request)?;
        let record = request.into_inner().record;
        if record.len() > 262144 {
            return Err(Status::invalid_argument("provider catalog byte bound"));
        }
        let catalog = weaver_contracts::decode(&record)
            .map_err(|_| Status::invalid_argument("provider catalog record"))?;
        let version = self
            .ingress
            .source()?
            .publish_catalog(caller, catalog)
            .await?;
        Ok(Response::new(pb::ProviderCatalogSnapshot {
            version,
            record,
        }))
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
