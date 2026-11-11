// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source ledger worker and transaction dispatch.
use super::command::{Command, Envelope, SourceDeployment};
use crate::runtime::ShutdownGuard;
use std::{path::PathBuf, sync::Arc};
use tokio::{
    runtime::Handle,
    sync::{OwnedSemaphorePermit, mpsc, oneshot},
};
use tokio_util::sync::CancellationToken;
use weaver_contracts::{Error, PublicationKey, Result, Task};
use weaver_ledger::Ledger;

pub(super) fn run(
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
    let mut catalog_projection = weaver_ledger::ProviderCatalogProjection::default();
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
        let (caller, command) = match command {
            Envelope::Source { caller, command } => (caller, *command),
            Envelope::RoutingCut {
                family,
                node,
                reply,
                slot,
            } => {
                let result = ledger.provider_operation_cut(&family, &node);
                answer(ledger, reply, result, slot)?;
                continue;
            }
            Envelope::RoutedTask {
                observed,
                task,
                plan,
                reply,
                slot,
            } => {
                let result = ledger.register_routed_task(&observed, &task, &plan);
                answer(ledger, reply, result, slot)?;
                continue;
            }
        };
        match command {
            Command::RegisterOperationSource { scope, reply, slot } => {
                let result = ledger.with_authenticated_source(&caller, |ledger| {
                    ledger.register_provider_source(&scope)
                });
                answer(ledger, reply, result, slot)?;
            }
            Command::InspectFact { reply, slot } => {
                let result =
                    ledger.with_authenticated_source(&caller, |ledger| ledger.inspect_fact_feed());
                answer(ledger, reply, result, slot)?;
            }
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
                let result = ledger.with_authenticated_source(&caller, |ledger| {
                    ledger.inspect_provider_catalog(&mut catalog_projection)
                });
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

fn register(ledger: &mut Ledger, task: &Task, publication: Option<&PublicationKey>) -> Result<()> {
    for endpoint in task.endpoints.values() {
        weaver_broker::HttpsTransport::validate_endpoint(endpoint)?;
    }
    match publication {
        Some(key) => ledger.register_published_task(task, key),
        None => ledger.register_task(task),
    }
}

pub(super) fn answer<T>(
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
