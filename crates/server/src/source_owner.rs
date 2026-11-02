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
    Error, Publication, PublicationKey, PublicationReceipt, Result, SourceAuthority,
    SourceIdentity, SourceRotation, SourceRotationReceipt, Task,
};
use weaver_ledger::Ledger;

#[derive(Clone)]
pub(crate) struct SourceOwner {
    sender: mpsc::Sender<Envelope>,
    capacity: Arc<Semaphore>,
}
struct Envelope {
    caller: SourceIdentity,
    command: Command,
}
enum Command {
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
    pub(crate) async fn start(
        runtime: RuntimeOwner,
        slot: Arc<OwnedSemaphorePermit>,
        database: PathBuf,
    ) -> Result<SourceWorker> {
        let (sender, receiver) = mpsc::channel(1);
        let (ready_tx, ready_rx) = oneshot::channel();
        let handle = Handle::current();
        let exit = runtime.shutdown_guard();
        let job = runtime.spawn_blocking(slot, move |cancel| {
            run(database, receiver, ready_tx, handle, cancel, exit)
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
    let result = if ready.send(Ok(())).is_err() {
        Err(Error::Conflict("source startup abandoned"))
    } else {
        process(&mut ledger, receiver, handle, cancel)
    };
    result.and(ledger.close())
}
fn process(
    ledger: &mut Ledger,
    mut receiver: mpsc::Receiver<Envelope>,
    handle: Handle,
    cancel: CancellationToken,
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
                        weaver_execution::HttpsTransport::validate_endpoint(endpoint)?;
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
                        weaver_execution::HttpsTransport::validate_endpoint(endpoint)?;
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
                let result =
                    ledger.with_authenticated_source(&caller, |l| l.publish_authority(&change));
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
        weaver_execution::HttpsTransport::validate_endpoint(endpoint)?;
    }
    match publication {
        Some(key) => ledger.register_published_task(task, key),
        None => ledger.register_task(task),
    }
}

#[cfg(test)]
#[path = "../tests/unit/source_owner.rs"]
mod tests;
