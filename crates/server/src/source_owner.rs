// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One tracked blocking owner for source-only Turso work; no cached authority decisions.
use crate::runtime::{RuntimeOwner, ShutdownGuard};
use std::{path::PathBuf, sync::Arc};
use tokio::{
    runtime::Handle,
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;
use tonic::Status;
use weaver_contracts::{
    Error, FactBarrier, FactFeed, FactIntent, FactResolution, FactWork, Publication,
    PublicationKey, PublicationReceipt, Result, SourceAuthority, SourceIdentity, SourceRotation,
    SourceRotationReceipt, Task,
};
use weaver_ledger::{FactPreparation, Ledger};

#[derive(Clone)]
pub(crate) struct SourceOwner {
    sender: mpsc::Sender<Envelope>,
    capacity: Arc<Semaphore>,
}
struct Envelope {
    caller: SourceIdentity,
    command: Command,
}
struct SourceDeployment {
    review: Option<weaver_contracts::ReviewAuthority>,
    metering: Option<weaver_contracts::MeteringDeployment>,
    oauth: Option<weaver_contracts::ProviderOAuthDeployment>,
    fact_feed: Option<FactFeed>,
    session_wakeup: Option<Arc<tokio::sync::Notify>>,
}

enum Command {
    StageFact {
        intent: FactIntent,
        reply: oneshot::Sender<Result<FactBarrier>>,
        slot: OwnedSemaphorePermit,
    },
    PrepareFact {
        barrier: FactBarrier,
        reply: oneshot::Sender<Result<FactPreparation>>,
        slot: OwnedSemaphorePermit,
    },
    ResolveFact {
        work: FactWork,
        affected: Vec<String>,
        reply: oneshot::Sender<Result<FactResolution>>,
        slot: OwnedSemaphorePermit,
    },
    ChangeProviderOAuth {
        action: Box<crate::pb::provider_o_auth_change::Action>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },
    RotateMeter {
        tenant: String,
        issuer: String,
        expected: u64,
        next: SourceIdentity,
        reply: oneshot::Sender<Result<u64>>,
        slot: OwnedSemaphorePermit,
    },

    TerminalUsage {
        family: String,
        node: String,
        reply: oneshot::Sender<Result<weaver_contracts::MeteringReceipt>>,
        slot: OwnedSemaphorePermit,
    },

    ReadCatalog {
        reply: oneshot::Sender<Result<Option<(String, weaver_contracts::ProviderCatalog)>>>,
        slot: OwnedSemaphorePermit,
    },
    PublishCatalog {
        catalog: weaver_contracts::ProviderCatalog,
        reply: oneshot::Sender<Result<String>>,
        slot: OwnedSemaphorePermit,
    },
    ApplyMetering {
        evidence: Box<weaver_contracts::MeteringReceipt>,
        reply: oneshot::Sender<Result<weaver_contracts::MeteringApplication>>,
        slot: OwnedSemaphorePermit,
    },
    Original {
        task: Box<Task>,
        domains: weaver_contracts::DomainBinding,
        admission: weaver_contracts::TaskAdmission,
        publication: Option<PublicationKey>,
        reply: oneshot::Sender<Result<weaver_contracts::TaskAdmissionReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    RegisterDomain {
        task: Box<Task>,
        domains: weaver_contracts::DomainBinding,
        publication: Option<PublicationKey>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },
    Alias {
        family: String,
        origin: String,
        reply: oneshot::Sender<Result<weaver_contracts::DomainView>>,
        slot: OwnedSemaphorePermit,
    },
    Domains {
        family: String,
        reply: oneshot::Sender<Result<weaver_contracts::DomainView>>,
        slot: OwnedSemaphorePermit,
    },
    Migrate {
        change: weaver_contracts::DomainMigration,
        reply: oneshot::Sender<Result<weaver_contracts::DomainMigrationReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    Authority {
        reply: oneshot::Sender<Result<SourceAuthority>>,
        slot: OwnedSemaphorePermit,
    },
    Rotate {
        change: SourceRotation,
        reply: oneshot::Sender<Result<SourceRotationReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    Stage {
        change: Publication,
        reply: oneshot::Sender<Result<PublicationKey>>,
        slot: OwnedSemaphorePermit,
    },
    Register {
        task: Box<Task>,
        publication: Option<PublicationKey>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },
    Publish {
        change: Publication,
        reply: oneshot::Sender<Result<PublicationReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    StageReviewed {
        change: Publication,
        reply: oneshot::Sender<Result<PublicationKey>>,
        slot: OwnedSemaphorePermit,
    },
    ReviewContext {
        key: PublicationKey,
        reply: oneshot::Sender<Result<weaver_contracts::PublicationReviewContext>>,
        slot: OwnedSemaphorePermit,
    },
    RegisterReview {
        evidence: Box<weaver_contracts::DeltaReview>,
        reply: oneshot::Sender<Result<String>>,
        slot: OwnedSemaphorePermit,
    },
    Inspect {
        key: PublicationKey,
        reply: oneshot::Sender<Result<Option<PublicationReceipt>>>,
        slot: OwnedSemaphorePermit,
    },
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
    pub(crate) async fn stage_fact(
        &self,
        caller: SourceIdentity,
        intent: FactIntent,
    ) -> std::result::Result<FactBarrier, Status> {
        self.submit(caller, |reply, slot| Command::StageFact {
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
        self.submit(caller, |reply, slot| Command::PrepareFact {
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
        self.submit(caller, |reply, slot| Command::ResolveFact {
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
            run(
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
            },
            job,
        })
    }
    async fn submit<T>(
        &self,
        caller: SourceIdentity,
        make: impl FnOnce(oneshot::Sender<Result<T>>, OwnedSemaphorePermit) -> Command,
    ) -> std::result::Result<T, Status> {
        let slot = self
            .capacity
            .clone()
            .try_acquire_owned()
            .map_err(|_| Status::resource_exhausted("source command lane full"))?;
        let (reply, receiver) = oneshot::channel();
        self.sender
            .try_send(Envelope {
                caller,
                command: make(reply, slot),
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
    pub(crate) async fn register(
        &self,
        caller: SourceIdentity,
        task: Task,
        publication: Option<PublicationKey>,
    ) -> std::result::Result<(), Status> {
        self.submit(caller, |reply, slot| Command::Register {
            task: Box::new(task),
            publication,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn publish(
        &self,
        caller: SourceIdentity,
        change: Publication,
    ) -> std::result::Result<PublicationReceipt, Status> {
        self.submit(caller, |reply, slot| Command::Publish {
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
        self.submit(caller, |reply, slot| Command::Stage {
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
        self.submit(caller, |reply, slot| Command::StageReviewed {
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
    ) -> std::result::Result<Option<(String, weaver_contracts::ProviderCatalog)>, Status> {
        self.submit(caller, |reply, slot| Command::ReadCatalog { reply, slot })
            .await
    }
    pub(crate) async fn publish_catalog(
        &self,
        caller: SourceIdentity,
        catalog: weaver_contracts::ProviderCatalog,
    ) -> std::result::Result<String, Status> {
        self.submit(caller, |reply, slot| Command::PublishCatalog {
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
        self.submit(caller, |reply, slot| Command::Rotate {
            change,
            reply,
            slot,
        })
        .await
    }
}
fn run(
    database: PathBuf,
    deployment: SourceDeployment,
    receiver: mpsc::Receiver<Envelope>,
    ready: oneshot::Sender<Result<()>>,
    handle: Handle,
    cancel: CancellationToken,
    _exit: ShutdownGuard,
) -> Result<()> {
    let mut ledger = match Ledger::open(database) {
        Ok(ledger) => ledger,
        Err(error) => {
            let _ = ready.send(Err(error));
            return Err(Error::Conflict("source database unavailable"));
        }
    };
    if let Some(authority) = deployment.review
        && let Err(error) = ledger.install_review_authority(&authority)
    {
        let _ = ready.send(Err(error));
        return ledger
            .close()
            .and(Err(Error::Conflict("review authority startup refused")));
    }
    if let Some(config) = &deployment.metering
        && let Err(error) = ledger.install_metering(config)
    {
        let _ = ready.send(Err(error));
        return ledger
            .close()
            .and(Err(Error::Conflict("metering startup refused")));
    }
    if let Err(error) = ledger.configure_provider_oauth(deployment.oauth.as_ref()) {
        let _ = ready.send(Err(error));
        return ledger
            .close()
            .and(Err(Error::Conflict("provider OAuth startup refused")));
    }
    if let Err(error) = ledger.configure_fact_feed(deployment.fact_feed.as_ref()) {
        let _ = ready.send(Err(error));
        return ledger
            .close()
            .and(Err(Error::Conflict("hard fact feed startup refused")));
    }
    let result = if ready.send(Ok(())).is_err() {
        Err(Error::Conflict("source startup abandoned"))
    } else {
        process(
            &mut ledger,
            receiver,
            handle,
            cancel,
            deployment.session_wakeup,
        )
    };
    result.and(ledger.close())
}
fn process(
    ledger: &mut Ledger,
    mut receiver: mpsc::Receiver<Envelope>,
    handle: Handle,
    cancel: CancellationToken,
    session_wakeup: Option<Arc<tokio::sync::Notify>>,
) -> Result<()> {
    loop {
        let command = handle.block_on(async {
            tokio::select! {
                biased;
                _=cancel.cancelled()=>None,
                command=receiver.recv()=>command,
            }
        });
        let Some(command) = command else {
            return Ok(());
        };
        ledger.require_quiescent()?;
        let Envelope { caller, command } = command;
        match command {
            Command::StageFact {
                intent,
                reply,
                slot,
            } => {
                let result = ledger
                    .with_authenticated_source(&caller, |ledger| ledger.stage_fact_intent(&intent));
                answer(ledger, reply, result, slot)?;
            }
            Command::PrepareFact {
                barrier,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |ledger| {
                    ledger.prepare_fact_projection(&barrier)
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::ResolveFact {
                work,
                affected,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |ledger| {
                    ledger.resolve_fact_projection(&work, affected)
                });
                if result.is_ok()
                    && let Some(wakeup) = &session_wakeup
                {
                    wakeup.notify_one();
                }
                answer(ledger, reply, result, slot)?;
            }
            Command::ChangeProviderOAuth {
                action,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |ledger| {
                    crate::provider_oauth::change(ledger, *action)
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::RotateMeter {
                tenant,
                issuer,
                expected,
                next,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |ledger| {
                    ledger.rotate_meter_credential(&tenant, &issuer, expected, &next)
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::TerminalUsage {
                family,
                node,
                reply,
                slot,
            } => {
                let result = ledger.inspect_terminal_usage(&caller, &family, &node);
                answer(ledger, reply, result, slot)?;
            }
            Command::ReadCatalog { reply, slot } => {
                let result =
                    ledger.with_authenticated_source(&caller, |ledger| ledger.provider_catalog());
                answer(ledger, reply, result, slot)?;
            }
            Command::PublishCatalog {
                catalog,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |ledger| {
                    ledger.publish_provider_catalog(&catalog)
                });
                if result.is_ok()
                    && let Some(wakeup) = &session_wakeup
                {
                    wakeup.notify_one();
                }
                answer(ledger, reply, result, slot)?;
            }
            Command::ApplyMetering {
                evidence,
                reply,
                slot,
            } => {
                let result = ledger.apply_metering_from(&evidence, Some(&caller));
                answer(ledger, reply, result, slot)?;
            }
            Command::Original {
                task,
                domains,
                admission,
                publication,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |l| {
                    for endpoint in task.endpoints.values() {
                        weaver_broker::HttpsTransport::validate_endpoint(endpoint)?;
                    }
                    l.register_original_task(&task, &domains, &admission, publication.as_ref())
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::RegisterDomain {
                task,
                domains,
                publication,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |l| {
                    for endpoint in task.endpoints.values() {
                        weaver_broker::HttpsTransport::validate_endpoint(endpoint)?;
                    }
                    l.register_task_domains(&task, &domains, publication.as_ref())
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::Alias {
                family,
                origin,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |l| {
                    l.register_family_alias(&family, &origin)
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::Domains {
                family,
                reply,
                slot,
            } => {
                let result =
                    ledger.with_authenticated_source(&caller, |l| l.execution_domains(&family));
                answer(ledger, reply, result, slot)?;
            }
            Command::Migrate {
                change,
                reply,
                slot,
            } => {
                #[cfg(all(test, unix))]
                crate::provider_commit_tests::mutation_started(&change.operation_id, "Mutation");
                let result = ledger
                    .with_authenticated_source(&caller, |l| l.migrate_execution_domains(&change));
                answer(ledger, reply, result, slot)?;
            }
            Command::Authority { reply, slot } => {
                let result = ledger.with_authenticated_source(&caller, |l| {
                    l.source_authority()?.ok_or(Error::Denied)
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::Rotate {
                change,
                reply,
                slot,
            } => {
                let result = ledger.rotate_source_authority(&caller, &change);
                answer(ledger, reply, result, slot)?;
            }
            Command::Stage {
                change,
                reply,
                slot,
            } => {
                let result =
                    ledger.with_authenticated_source(&caller, |l| l.stage_authority(&change));
                answer(ledger, reply, result, slot)?;
            }
            Command::Register {
                task,
                publication,
                reply,
                slot,
            } => {
                let result = ledger.with_authenticated_source(&caller, |l| {
                    register(l, &task, publication.as_ref())
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::Publish {
                change,
                reply,
                slot,
            } => {
                #[cfg(all(test, unix))]
                crate::provider_commit_tests::mutation_started(&change.operation_id, "Publish");
                let result =
                    ledger.with_authenticated_source(&caller, |l| l.publish_authority(&change));
                answer(ledger, reply, result, slot)?;
            }
            Command::StageReviewed {
                change,
                reply,
                slot,
            } => {
                #[cfg(all(test, unix))]
                crate::provider_commit_tests::mutation_started(&change.operation_id, "Stage");
                let result = ledger
                    .with_authenticated_source(&caller, |l| l.stage_reviewed_authority(&change));
                answer(ledger, reply, result, slot)?;
            }
            Command::ReviewContext { key, reply, slot } => {
                let result = ledger
                    .with_authenticated_source(&caller, |l| l.publication_review_context(&key));
                answer(ledger, reply, result, slot)?;
            }
            Command::RegisterReview {
                evidence,
                reply,
                slot,
            } => {
                let result = ledger
                    .with_authenticated_source(&caller, |l| l.register_delta_review(&evidence));
                answer(ledger, reply, result, slot)?;
            }
            Command::Inspect { key, reply, slot } => {
                let result =
                    ledger.with_authenticated_source(&caller, |l| l.publication_receipt(&key));
                answer(ledger, reply, result, slot)?;
            }
        }
    }
}
fn answer<T>(
    ledger: &Ledger,
    reply: oneshot::Sender<Result<T>>,
    result: Result<T>,
    slot: OwnedSemaphorePermit,
) -> Result<()> {
    ledger.require_quiescent()?;
    if matches!(&result, Err(Error::Storage(_))) {
        return Err(Error::Conflict(
            "source storage outcome unknown; owner cannot be reused",
        ));
    }
    // Acknowledgment permits immediate reuse. Retain custody through SQL and its
    // quiescence check, then return capacity before a caller can observe success.
    drop(slot);
    let _ = reply.send(result);
    Ok(())
}
fn register(ledger: &mut Ledger, task: &Task, publication: Option<&PublicationKey>) -> Result<()> {
    for endpoint in task.endpoints.values() {
        weaver_broker::HttpsTransport::validate_endpoint(endpoint)?;
    }
    match publication {
        Some(key) => ledger.register_published_task(task, key),
        None => ledger.register_task(task),
    }
}

#[cfg(test)]
#[path = "../tests/unit/source_owner.rs"]
mod tests;
