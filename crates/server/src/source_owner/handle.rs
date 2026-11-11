// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One tracked blocking owner for source-only Turso work; no cached authority decisions.
use super::{
    command::{Command, Envelope, SourceDeployment},
    worker,
};
use crate::runtime::RuntimeOwner;
use std::{path::PathBuf, sync::Arc};
use tokio::{
    runtime::Handle,
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
};
use tonic::Status;
use weaver_contracts::{
    Error, FactBarrier, FactIntent, FactResolution, FactWork, Publication, PublicationKey,
    PublicationReceipt, Result, SourceAuthority, SourceIdentity, SourceRotation,
    SourceRotationReceipt, Task,
};
use weaver_ledger::FactPreparation;

#[derive(Clone)]
pub(crate) struct SourceOwner {
    sender: mpsc::Sender<Envelope>,
    capacity: Arc<Semaphore>,
    waiting: Arc<Semaphore>,
    next_mutation: Arc<MutationHandoff>,
    routing: Arc<tokio::sync::Mutex<Option<OperationProjection>>>,
}
#[derive(Clone)]
pub(crate) struct OperationResolver(SourceOwner);
enum OperationProjection {
    Fixed(Arc<weaver_contracts::ProviderPlan>),
    Catalog(Box<RoutingProjection>),
}
struct RoutingProjection {
    binding: weaver_contracts::ProviderOperationBinding,
    version: String,
    revision: u64,
    fence: u64,
    selected: weaver_governance::OwnedSource,
}
impl OperationResolver {
    pub(crate) async fn resolve(
        &self,
        runtime: &RuntimeOwner,
        family: String,
        node: String,
        expected: &str,
    ) -> std::result::Result<(weaver_contracts::ProviderPlan, String), Status> {
        self.0
            .resolve_operation(runtime, family, node, expected)
            .await
    }
}
#[derive(Default)]
struct MutationHandoff {
    pending: std::sync::atomic::AtomicBool,
    released: tokio::sync::Notify,
}
impl MutationHandoff {
    fn pending(&self) -> bool {
        self.pending.load(std::sync::atomic::Ordering::Acquire)
    }

    fn reserve(&self) -> Option<MutationReservation<'_>> {
        use std::sync::atomic::Ordering;
        self.pending
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| MutationReservation(self))
    }

    async fn released(&self) {
        loop {
            let released = self.released.notified();
            if !self.pending() {
                return;
            }
            released.await;
        }
    }
}
struct MutationReservation<'a>(&'a MutationHandoff);
impl Drop for MutationReservation<'_> {
    fn drop(&mut self) {
        self.0
            .pending
            .store(false, std::sync::atomic::Ordering::Release);
        self.0.released.notify_waiters();
    }
}

pub(crate) struct SourceWorker {
    pub(crate) client: SourceOwner,
    job: tokio::task::JoinHandle<Result<()>>,
}
impl SourceWorker {
    pub(crate) async fn finish(self) -> Result<()> {
        self.job
            .await
            .map_err(|_| Error::Conflict("source worker panicked"))?
    }
}
impl SourceOwner {
    pub(crate) async fn inspect_fact(
        &self,
        caller: SourceIdentity,
    ) -> std::result::Result<weaver_ledger::FactFeedState, Status> {
        self.submit_priority(caller, |reply, slot| Command::InspectFact { reply, slot })
            .await
    }

    pub(crate) async fn stage_fact(
        &self,
        caller: SourceIdentity,
        intent: FactIntent,
    ) -> std::result::Result<FactBarrier, Status> {
        self.submit_priority(caller, |reply, slot| Command::StageFact {
            intent,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn prepare_fact(
        &self,
        caller: SourceIdentity,
        barrier: FactBarrier,
    ) -> std::result::Result<FactPreparation, Status> {
        self.submit_priority(caller, |reply, slot| Command::PrepareFact {
            barrier,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn resolve_fact(
        &self,
        caller: SourceIdentity,
        work: FactWork,
        affected: Vec<String>,
    ) -> std::result::Result<FactResolution, Status> {
        self.submit_priority(caller, |reply, slot| Command::ResolveFact {
            work,
            affected,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn original(
        &self,
        caller: SourceIdentity,
        task: Task,
        domains: weaver_contracts::DomainBinding,
        admission: weaver_contracts::TaskAdmission,
        publication: Option<PublicationKey>,
    ) -> std::result::Result<weaver_contracts::TaskAdmissionReceipt, Status> {
        self.submit(caller, |reply, slot| Command::Original {
            task: Box::new(task),
            domains,
            admission,
            publication,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn register_domain(
        &self,
        caller: SourceIdentity,
        task: Task,
        domains: weaver_contracts::DomainBinding,
        publication: Option<PublicationKey>,
    ) -> std::result::Result<(), Status> {
        self.submit(caller, |reply, slot| Command::RegisterDomain {
            task: Box::new(task),
            domains,
            publication,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn alias(
        &self,
        caller: SourceIdentity,
        family: String,
        origin: String,
    ) -> std::result::Result<weaver_contracts::DomainView, Status> {
        self.submit(caller, |reply, slot| Command::Alias {
            family,
            origin,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn domains(
        &self,
        caller: SourceIdentity,
        family: String,
    ) -> std::result::Result<weaver_contracts::DomainView, Status> {
        self.submit(caller, |reply, slot| Command::Domains {
            family,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn migrate(
        &self,
        caller: SourceIdentity,
        change: weaver_contracts::DomainMigration,
    ) -> std::result::Result<weaver_contracts::DomainMigrationReceipt, Status> {
        self.submit(caller, |reply, slot| Command::Migrate {
            change,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn rotate_meter(
        &self,
        caller: SourceIdentity,
        tenant: String,
        issuer: String,
        expected: u64,
        next: SourceIdentity,
    ) -> std::result::Result<u64, Status> {
        self.submit(caller, |reply, slot| Command::RotateMeter {
            tenant,
            issuer,
            expected,
            next,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn terminal_usage(
        &self,
        caller: SourceIdentity,
        family: String,
        node: String,
    ) -> std::result::Result<weaver_contracts::MeteringReceipt, Status> {
        self.submit(caller, |reply, slot| Command::TerminalUsage {
            family,
            node,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn apply_metering(
        &self,
        caller: SourceIdentity,
        evidence: weaver_contracts::MeteringReceipt,
    ) -> std::result::Result<weaver_contracts::MeteringApplication, Status> {
        self.submit(caller, |reply, slot| Command::ApplyMetering {
            evidence: Box::new(evidence),
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn change_provider_oauth(
        &self,
        caller: SourceIdentity,
        action: crate::pb::provider_o_auth_change::Action,
    ) -> std::result::Result<(), Status> {
        self.submit(caller, |reply, slot| Command::ChangeProviderOAuth {
            action: Box::new(action),
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn start_reviewed(
        runtime: RuntimeOwner,
        slot: Arc<OwnedSemaphorePermit>,
        database: PathBuf,
        authority: weaver_contracts::ReviewAuthority,
        metering: Option<weaver_contracts::MeteringDeployment>,
        oauth: Option<weaver_contracts::ProviderOAuthDeployment>,
    ) -> Result<SourceWorker> {
        authority.validate()?;
        let fact_feed = runtime.fact_feed().cloned();
        let session_wakeup = runtime.session_wakeup().cloned();
        Self::start_inner(
            runtime,
            slot,
            database,
            SourceDeployment {
                review: Some(authority),
                metering,
                oauth,
                fact_feed,
                session_wakeup,
            },
        )
        .await
    }
    #[cfg(test)]
    pub(crate) async fn start(
        runtime: RuntimeOwner,
        slot: Arc<OwnedSemaphorePermit>,
        database: PathBuf,
    ) -> Result<SourceWorker> {
        Self::start_inner(
            runtime,
            slot,
            database,
            SourceDeployment {
                review: None,
                metering: None,
                oauth: None,
                fact_feed: None,
                session_wakeup: None,
            },
        )
        .await
    }
    async fn start_inner(
        runtime: RuntimeOwner,
        slot: Arc<OwnedSemaphorePermit>,
        database: PathBuf,
        deployment: SourceDeployment,
    ) -> Result<SourceWorker> {
        let (sender, receiver) = mpsc::channel(1);
        let (ready_tx, ready_rx) = oneshot::channel();
        let handle = Handle::current();
        let exit = runtime.shutdown_guard();
        let job = runtime.spawn_blocking(slot, move |cancel| {
            worker::run(
                database, deployment, receiver, ready_tx, handle, cancel, exit,
            )
        })?;
        let ready = ready_rx
            .await
            .map_err(|_| Error::Conflict("source owner startup failed"))
            .and_then(|result| result);
        if let Err(error) = ready {
            let _ = job.await;
            return Err(error);
        }
        Ok(SourceWorker {
            client: Self {
                sender,
                capacity: Arc::new(Semaphore::new(1)),
                waiting: Arc::new(Semaphore::new(3)),
                next_mutation: Arc::new(MutationHandoff::default()),
                routing: Arc::new(tokio::sync::Mutex::new(None)),
            },
            job,
        })
    }
    async fn submit<T>(
        &self,
        caller: SourceIdentity,
        make: impl FnOnce(oneshot::Sender<Result<T>>, OwnedSemaphorePermit) -> Command,
    ) -> std::result::Result<T, Status> {
        self.submit_with_wait(caller, false, make).await
    }
    async fn command_slot(&self, wait: bool) -> std::result::Result<OwnedSemaphorePermit, Status> {
        if let Ok(slot) = self.capacity.clone().try_acquire_owned()
            && !self.next_mutation.pending()
        {
            return Ok(slot);
        }
        if !wait {
            return Err(Status::resource_exhausted("source command lane full"));
        }
        let _waiting = self
            .waiting
            .clone()
            .try_acquire_owned()
            .map_err(|_| Status::resource_exhausted("source command wait limit"))?;
        self.wait_slot(async {
            loop {
                let slot = self
                    .capacity
                    .clone()
                    .acquire_owned()
                    .await
                    .map_err(|_| Status::unavailable("source owner stopped"))?;
                if !self.next_mutation.pending() {
                    return Ok(slot);
                }
                // Yield this handoff to the reserved mutation. Retain only the
                // bounded waiting slot while the mutation reaches the owner.
                drop(slot);
                self.next_mutation.released().await;
            }
        })
        .await
    }
    async fn wait_slot(
        &self,
        future: impl std::future::Future<Output = std::result::Result<OwnedSemaphorePermit, Status>>,
    ) -> std::result::Result<OwnedSemaphorePermit, Status> {
        tokio::select! {
            biased;
            _ = self.sender.closed() => Err(Status::unavailable("source owner stopped")),
            slot = tokio::time::timeout(std::time::Duration::from_millis(50), future) =>
                slot.map_err(|_| Status::resource_exhausted("source command wait expired"))?,
        }
    }
    async fn priority_slot(&self) -> std::result::Result<OwnedSemaphorePermit, Status> {
        let _next = self
            .next_mutation
            .reserve()
            .ok_or_else(|| Status::resource_exhausted("source mutation wait limit"))?;
        self.wait_slot(async {
            self.capacity
                .clone()
                .acquire_owned()
                .await
                .map_err(|_| Status::unavailable("source owner stopped"))
        })
        .await
    }
    async fn submit_priority<T>(
        &self,
        caller: SourceIdentity,
        make: impl FnOnce(oneshot::Sender<Result<T>>, OwnedSemaphorePermit) -> Command,
    ) -> std::result::Result<T, Status> {
        let slot = self.priority_slot().await?;
        self.submit_acquired(caller, slot, make).await
    }
    async fn submit_with_wait<T>(
        &self,
        caller: SourceIdentity,
        wait: bool,
        make: impl FnOnce(oneshot::Sender<Result<T>>, OwnedSemaphorePermit) -> Command,
    ) -> std::result::Result<T, Status> {
        let slot = self.command_slot(wait).await?;
        self.submit_acquired(caller, slot, make).await
    }
    async fn submit_acquired<T>(
        &self,
        caller: SourceIdentity,
        slot: OwnedSemaphorePermit,
        make: impl FnOnce(oneshot::Sender<Result<T>>, OwnedSemaphorePermit) -> Command,
    ) -> std::result::Result<T, Status> {
        let (reply, receiver) = oneshot::channel();
        self.sender
            .try_send(Envelope::Source {
                caller,
                command: Box::new(make(reply, slot)),
            })
            .map_err(|_| Status::unavailable("source owner stopped"))?;
        receiver
            .await
            .map_err(|_| Status::unavailable("source result unknown; reconcile original identity"))?
            .map_err(|error| match error {
                Error::Denied => {
                    Status::permission_denied("source identity retired or unqualified")
                }
                _ => Status::failed_precondition("source authority or state rejected"),
            })
    }
    pub(crate) async fn register_operation_source(
        &self,
        caller: SourceIdentity,
        scope: weaver_contracts::ProviderOperationScope,
    ) -> std::result::Result<(), Status> {
        self.submit_with_wait(caller, true, |reply, slot| {
            Command::RegisterOperationSource {
                scope: Box::new(scope),
                reply,
                slot,
            }
        })
        .await
    }
    async fn internal<T>(
        &self,
        make: impl FnOnce(oneshot::Sender<Result<T>>, OwnedSemaphorePermit) -> Envelope,
    ) -> std::result::Result<T, Status> {
        let slot = self.command_slot(true).await?;
        let (reply, receive) = oneshot::channel();
        self.sender
            .try_send(make(reply, slot))
            .map_err(|_| Status::unavailable("source owner stopped"))?;
        receive
            .await
            .map_err(|_| Status::unavailable("source routing result unknown"))?
            .map_err(crate::grpc_contracts::status)
    }
    pub(crate) fn operation_resolver(&self) -> OperationResolver {
        OperationResolver(self.clone())
    }
    async fn resolve_operation(
        &self,
        runtime: &RuntimeOwner,
        family: String,
        node: String,
        expected: &str,
    ) -> std::result::Result<(weaver_contracts::ProviderPlan, String), Status> {
        // This hit returns inert immutable data only. The original activation
        // coordinates remain sealed and the broker performs all fresh deciding
        // checks. Catalog derivations always rejoin the source lane below.
        let cached = {
            let projection = self.routing.lock().await;
            match projection.as_ref() {
                Some(OperationProjection::Fixed(plan))
                    if plan.family == family && plan.node == node =>
                {
                    Some(plan.clone())
                }
                _ => None,
            }
        };
        if let Some(plan) = cached {
            return Ok((plan.as_ref().clone(), String::new()));
        }
        let observed = self
            .internal(|reply, slot| Envelope::RoutingCut {
                family,
                node,
                reply,
                slot,
            })
            .await?
            .ok_or(Status::failed_precondition(
                "source routing scope unavailable",
            ))?;
        if let weaver_contracts::ProviderOperationScope::Fixed { plan, .. } =
            &observed.binding.scope
        {
            let mut plan = plan.clone();
            plan.revision = observed.revision;
            plan.fence = observed.fence;
            *self.routing.lock().await = Some(OperationProjection::Fixed(Arc::new(plan.clone())));
            return Ok((plan, String::new()));
        }
        if !expected.is_empty() && expected != observed.catalog_version {
            return Err(Status::failed_precondition(
                "provider catalog coordinate changed",
            ));
        }
        let mut projection = self.routing.lock().await;
        let reusable = match projection.as_ref() {
            Some(OperationProjection::Catalog(p))
                if p.binding == observed.binding
                    && p.version == observed.catalog_version
                    && p.revision == observed.revision
                    && p.fence == observed.fence =>
            {
                Some(p)
            }
            _ => None,
        };
        let selected = if let Some(prior) = reusable {
            prior.selected.clone()
        } else {
            let weaver_contracts::ProviderOperationScope::Catalog { routing: scope } =
                &observed.binding.scope
            else {
                unreachable!()
            };
            let input = weaver_governance::SourceComposition {
                source: weaver_governance::SourceData {
                    governance: weaver_governance::SourceSelection {
                        schema: scope.selection_schema.clone(),
                        family: scope.task.family.clone(),
                        open_nodes: scope.task.nodes.clone(),
                        workflow_edges: Vec::new(),
                        workflow_selectors: Vec::new(),
                    },
                    tasks: vec![scope.task.clone()],
                    plans: Vec::new(),
                    publication: scope.publication.clone(),
                },
                routing: vec![scope.selection.clone()],
            };
            let selected =
                crate::source_composition::compose_typed(runtime, input, observed.catalog.as_ref())
                    .await?;
            *projection = Some(OperationProjection::Catalog(Box::new(RoutingProjection {
                binding: observed.binding.clone(),
                version: observed.catalog_version.clone(),
                revision: observed.revision,
                fence: observed.fence,
                selected: selected.clone(),
            })));
            selected
        };
        drop(projection);
        let mut plan = selected
            .plans()
            .first()
            .ok_or(Status::failed_precondition("source routing plan missing"))?
            .clone();
        let task = selected.task().clone();
        let version = observed.catalog_version.clone();
        let revision = observed.revision;
        let fence = observed.fence;
        self.internal(|reply, slot| Envelope::RoutedTask {
            observed: Box::new(observed),
            task: Box::new(task),
            plan: Box::new(plan.clone()),
            reply,
            slot,
        })
        .await?;
        plan.revision = revision;
        plan.fence = fence;
        Ok((plan, version))
    }
    pub(crate) async fn register(
        &self,
        caller: SourceIdentity,
        task: Task,
        publication: Option<PublicationKey>,
    ) -> std::result::Result<(), Status> {
        self.submit_with_wait(caller, publication.is_some(), |reply, slot| {
            Command::Register {
                task: Box::new(task),
                publication,
                reply,
                slot,
            }
        })
        .await
    }
    pub(crate) async fn publish(
        &self,
        caller: SourceIdentity,
        change: Publication,
    ) -> std::result::Result<PublicationReceipt, Status> {
        self.submit_priority(caller, |reply, slot| Command::Publish {
            change,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn stage(
        &self,
        caller: SourceIdentity,
        change: Publication,
    ) -> std::result::Result<PublicationKey, Status> {
        self.submit_priority(caller, |reply, slot| Command::Stage {
            change,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn inspect(
        &self,
        caller: SourceIdentity,
        key: PublicationKey,
    ) -> std::result::Result<Option<PublicationReceipt>, Status> {
        self.submit(caller, |reply, slot| Command::Inspect { key, reply, slot })
            .await
    }
    pub(crate) async fn stage_reviewed(
        &self,
        caller: SourceIdentity,
        change: Publication,
    ) -> std::result::Result<PublicationKey, Status> {
        self.submit_priority(caller, |reply, slot| Command::StageReviewed {
            change,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn review_context(
        &self,
        caller: SourceIdentity,
        key: PublicationKey,
    ) -> std::result::Result<weaver_contracts::PublicationReviewContext, Status> {
        self.submit(caller, |reply, slot| Command::ReviewContext {
            key,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn register_review(
        &self,
        caller: SourceIdentity,
        evidence: weaver_contracts::DeltaReview,
    ) -> std::result::Result<String, Status> {
        self.submit(caller, |reply, slot| Command::RegisterReview {
            evidence: Box::new(evidence),
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn provider_catalog(
        &self,
        caller: SourceIdentity,
    ) -> std::result::Result<Option<(String, Vec<u8>)>, Status> {
        self.submit_with_wait(caller, true, |reply, slot| Command::ReadCatalog {
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn publish_catalog(
        &self,
        caller: SourceIdentity,
        catalog: weaver_contracts::ProviderCatalog,
    ) -> std::result::Result<String, Status> {
        self.submit_priority(caller, |reply, slot| Command::PublishCatalog {
            catalog,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn authority(
        &self,
        caller: SourceIdentity,
    ) -> std::result::Result<SourceAuthority, Status> {
        self.submit(caller, |reply, slot| Command::Authority { reply, slot })
            .await
    }
    pub(crate) async fn rotate(
        &self,
        caller: SourceIdentity,
        change: SourceRotation,
    ) -> std::result::Result<SourceRotationReceipt, Status> {
        self.submit_priority(caller, |reply, slot| Command::Rotate {
            change,
            reply,
            slot,
        })
        .await
    }
}
#[cfg(test)]
#[path = "../../tests/unit/source_owner.rs"]
mod tests;
