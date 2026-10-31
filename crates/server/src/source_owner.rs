//! One tracked blocking owner for source-only SQLite work; no cached authority decisions.
use crate::runtime::RuntimeOwner;
use std::{path::PathBuf, sync::Arc};
use tokio::{
    runtime::Handle,
    sync::{OwnedSemaphorePermit, Semaphore, mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;
use tonic::Status;
use weaver_contracts::{Error, Publication, PublicationKey, PublicationReceipt, Result, Task};
use weaver_ledger::Ledger;

#[derive(Clone)]
pub(crate) struct SourceOwner {
    sender: mpsc::Sender<Command>,
    capacity: Arc<Semaphore>,
}
enum Command {
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
struct Exit {
    runtime: RuntimeOwner,
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
impl Drop for Exit {
    fn drop(&mut self) {
        self.runtime.request_shutdown();
    }
}
impl SourceOwner {
    pub(crate) async fn start(
        runtime: RuntimeOwner,
        slot: Arc<OwnedSemaphorePermit>,
        database: PathBuf,
    ) -> Result<SourceWorker> {
        let (sender, receiver) = mpsc::channel(1);
        let (ready_tx, ready_rx) = oneshot::channel();
        let handle = Handle::current();
        let exit = Exit {
            runtime: runtime.clone(),
        };
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
        make: impl FnOnce(oneshot::Sender<Result<T>>, OwnedSemaphorePermit) -> Command,
    ) -> std::result::Result<T, Status> {
        let slot = self
            .capacity
            .clone()
            .try_acquire_owned()
            .map_err(|_| Status::resource_exhausted("source command lane full"))?;
        let (reply, receiver) = oneshot::channel();
        self.sender
            .try_send(make(reply, slot))
            .map_err(|_| Status::unavailable("source owner stopped"))?;
        receiver
            .await
            .map_err(|_| Status::unavailable("source result unknown; reconcile original identity"))?
            .map_err(|_| Status::failed_precondition("source authority or state rejected"))
    }
    pub(crate) async fn register(
        &self,
        task: Task,
        publication: Option<PublicationKey>,
    ) -> std::result::Result<(), Status> {
        self.submit(|reply, slot| Command::Register {
            task: Box::new(task),
            publication,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn publish(
        &self,
        change: Publication,
    ) -> std::result::Result<PublicationReceipt, Status> {
        self.submit(|reply, slot| Command::Publish {
            change,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn stage(
        &self,
        change: Publication,
    ) -> std::result::Result<PublicationKey, Status> {
        self.submit(|reply, slot| Command::Stage {
            change,
            reply,
            slot,
        })
        .await
    }
    pub(crate) async fn inspect(
        &self,
        key: PublicationKey,
    ) -> std::result::Result<Option<PublicationReceipt>, Status> {
        self.submit(|reply, slot| Command::Inspect { key, reply, slot })
            .await
    }
}
fn run(
    database: PathBuf,
    receiver: mpsc::Receiver<Command>,
    ready: oneshot::Sender<Result<()>>,
    handle: Handle,
    cancel: CancellationToken,
    _exit: Exit,
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
    mut receiver: mpsc::Receiver<Command>,
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
        match command {
            Command::Stage {
                change,
                reply,
                slot,
            } => {
                let result = ledger.stage_authority(&change);
                answer(ledger, reply, result, slot)?;
            }
            Command::Register {
                task,
                publication,
                reply,
                slot,
            } => {
                let result = register(ledger, &task, publication.as_ref());
                answer(ledger, reply, result, slot)?;
            }
            Command::Publish {
                change,
                reply,
                slot,
            } => {
                let result = ledger.publish_authority(&change);
                answer(ledger, reply, result, slot)?;
            }
            Command::Inspect { key, reply, slot } => {
                let result = ledger.publication_receipt(&key);
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
