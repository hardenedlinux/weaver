// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Provider RPC lifecycle; source publication and server transport stay separate.
use crate::grpc::{Gateway, ResponseStream};
use crate::grpc_contracts::{plan, status};
use crate::{grpc_output::Output, pb, rpc_security::RpcRole};
use std::sync::Arc;
use tokio::sync::{OwnedSemaphorePermit, mpsc};
use tokio_util::sync::CancellationToken;
use tonic::{Request, Response, Status};
use weaver_contracts::{ProviderOAuthUse, ProviderPlan};
use weaver_ledger::{Ledger, WorkflowObservation};

pub(crate) struct StreamSettings {
    pub arrow: bool,
    pub batch_rows: u32,
    pub catalog: String,
}

#[derive(Default)]
pub(crate) struct WorkflowAdmission {
    pub predecessors: Vec<ProviderPlan>,
    pub observed: Option<Arc<WorkflowObservation>>,
}

impl Gateway {
    /// Use the immutable Governor-approved plans from the retired preparation
    /// owner. No request supplies an observation, transition or source graph.
    fn workflow_predecessors(
        &self,
        successor: &weaver_contracts::ProviderPlan,
    ) -> Result<Vec<ProviderPlan>, Status> {
        let Some(feed) = self
            .runtime
            .fact_feed()
            .filter(|feed| feed.family == successor.family)
        else {
            return Ok(Vec::new());
        };
        let predecessors = feed.workflow_predecessors(&successor.node);
        let session = !feed.workflow_path.is_empty();
        if predecessors.is_empty() && !session {
            return Ok(Vec::new());
        }
        let source = self
            .runtime
            .single_provider()
            .filter(|lifecycle| lifecycle.activated())
            .and_then(|lifecycle| lifecycle.ready.get())
            .map(crate::single_provider::Prepared::source)
            .ok_or(Status::failed_precondition(
                "compiled workflow has not activated",
            ))?;
        let selection = &source.data().governance;
        let matches_path = if session {
            selection.schema == feed.session_schema() && selection.open_nodes == feed.workflow_path
        } else {
            predecessors.iter().all(|node| {
                selection
                    .open_nodes
                    .iter()
                    .any(|selected| selected == *node)
            })
        };
        if selection.family != feed.family
            || !selection.open_nodes.contains(&successor.node)
            || !matches_path
        {
            return Err(Status::failed_precondition(
                "Governor workflow selection changed",
            ));
        }
        let admitted = |node: &str| {
            source
                .plans()
                .iter()
                .find(|p| p.family == selection.family && p.node == node)
                .ok_or(Status::failed_precondition(
                    "compiled workflow plan missing",
                ))
        };
        if admitted(&successor.node)? != successor {
            return Err(Status::failed_precondition(
                "successor differs from compiled original",
            ));
        }
        predecessors
            .into_iter()
            .map(|node| admitted(node).cloned())
            .collect()
    }

    pub(super) async fn execute_provider_stream(
        &self,
        request: Request<pb::ProviderRequest>,
    ) -> std::result::Result<Response<ResponseStream>, Status> {
        self.authenticate(&request, RpcRole::Operation)?;
        let oauth = crate::provider_oauth::observe(self.provider_oauth_enabled, &request)?;
        if !cfg!(feature = "llm-provider") {
            return Err(Status::unimplemented("LLM provider feature disabled"));
        }
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
        let predecessors = self.workflow_predecessors(&plan)?;
        if self
            .runtime
            .fact_feed()
            .is_some_and(|feed| !feed.workflow_path.is_empty() && feed.family == plan.family)
            && !predecessors.is_empty()
        {
            return Err(Status::failed_precondition(
                "Session owns successor execution",
            ));
        }
        self.start_provider_stream(
            slot,
            plan,
            WorkflowAdmission {
                predecessors,
                observed: None,
            },
            oauth,
            StreamSettings {
                arrow,
                batch_rows: request.batch_rows,
                catalog: request.catalog_version,
            },
        )
        .map(Response::new)
    }

    pub(crate) fn start_provider_stream(
        &self,
        slot: Arc<OwnedSemaphorePermit>,
        plan: ProviderPlan,
        workflow: WorkflowAdmission,
        oauth: Option<ProviderOAuthUse>,
        settings: StreamSettings,
    ) -> Result<ResponseStream, Status> {
        let StreamSettings {
            arrow,
            batch_rows,
            catalog,
        } = settings;
        let cursor = weaver_ledger::DeliveryCursor::new(&plan).map_err(status)?;
        let (sender, receiver) = mpsc::channel(crate::grpc_output::DELIVERY_QUEUE_CAPACITY);
        let cancelled = CancellationToken::new();
        let mut output = Output {
            telemetry: self.runtime.telemetry().clone(),
            pending: None,
            deliveries: Default::default(),
            sender: sender.clone(),
            cancelled: cancelled.clone(),
            shutdown: CancellationToken::new(),
            runtime: tokio::runtime::Handle::current(),
        };
        let config = self.config.clone();
        let transport = self.transport.clone();
        let wakeup = self
            .runtime
            .session_wakeup()
            .filter(|_| {
                self.runtime
                    .fact_feed()
                    .is_some_and(|feed| feed.family == plan.family)
            })
            .cloned();
        let session_root = wakeup.is_some() && workflow.predecessors.is_empty();
        #[cfg(test)]
        let trace_scopes = std::env::var_os("WEAVER_TEST_PROVIDER_SCOPE_TRACE").is_some();
        #[cfg(test)]
        let reuse = std::env::var_os("WEAVER_TEST_REUSE_PROVIDER_CONNECTION").is_some();
        #[cfg(test)]
        let custody = self.admission.clone();
        #[cfg(test)]
        let queued_ticks =
            trace_scopes.then(weaver_ledger::persistence::provider_observation_nanos);
        #[cfg(test)]
        let queued_at = std::time::Instant::now();
        let job = self
            .runtime
            .spawn_blocking(slot, move |shutdown| {
                #[cfg(test)]
                let worker_started = std::time::Instant::now();
                output.shutdown = shutdown;
                let result = (|| {
                    #[cfg(test)]
                    let open_started = std::time::Instant::now();
                    #[cfg(test)]
                    let (mut ledger, reused) = if reuse {
                        custody.checkout_provider(&config.database, &output.shutdown)?
                    } else {
                        (Ledger::open(&config.database)?, false)
                    };
                    #[cfg(not(test))]
                    let mut ledger = Ledger::open(&config.database)?;
                    let client = output.cancelled.clone();
                    let server = output.shutdown.clone();
                    ledger.set_provider_range_cancellation(move || client.is_cancelled() || server.is_cancelled());
                    #[cfg(test)]
                    let open_nanos = open_started.elapsed().as_nanos();
                    #[cfg(all(test, unix))]
                    crate::provider_commit_tests::attach(&mut ledger);
                    ledger.require_principal(&config.principal, &plan.family)?;
                    #[cfg(test)]
                    weaver_ledger::persistence::use_cached_currentness_plans(
                        std::env::var("WEAVER_TEST_CACHE_CURRENTNESS_PLANS").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_prepared_manifest_programs(
                        std::env::var("WEAVER_TEST_PREPARED_MANIFEST_PROGRAMS").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_prepared_original_program(
                        std::env::var("WEAVER_TEST_PREPARED_ORIGINAL_PROGRAM").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_locked_publication_review(
                        std::env::var("WEAVER_TEST_LOCKED_PUBLICATION_REVIEW").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_locked_original_evidence(
                        std::env::var("WEAVER_TEST_LOCKED_ORIGINAL_EVIDENCE").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_fresh_provider_domain_plan(
                        std::env::var("WEAVER_TEST_FRESH_PROVIDER_DOMAIN_PLAN").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_separate_release_reads(
                        std::env::var("WEAVER_TEST_SEPARATE_RELEASE_READS").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_early_admission_barrier(std::env::var_os("WEAVER_TEST_EARLY_ADMISSION_BARRIER").is_some());
                    #[cfg(test)]
                    weaver_ledger::use_exclusive_provider_reads(
                        std::env::var_os("WEAVER_TEST_EXCLUSIVE_PROVIDER_READS").is_some(),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_full_lifecycle_invalidation(

                        std::env::var_os("WEAVER_TEST_FULL_LIFECYCLE_INVALIDATION").is_some(),
                    );
                    #[cfg(test)]
                    weaver_ledger::use_conservative_range_invalidation(
                        std::env::var_os("WEAVER_TEST_CONSERVATIVE_RANGE_INVALIDATION").is_some(),
                    );
                    #[cfg(test)]
                    if trace_scopes {
                        let node = std::env::var_os("WEAVER_TEST_PROVIDER_SCOPE_TIMELINE")
                            .is_some()
                            .then_some(plan.node.as_str());
                        ledger.trace_provider_scopes(&plan.family, node);
                    }
                    #[cfg(test)]
                    weaver_ledger::use_cached_release_programs(
                        std::env::var("WEAVER_TEST_CACHED_RELEASE_PROGRAMS").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    {
                        crate::grpc_output::take_encoding_nanos();
                        crate::grpc_output::take_transport();
                        crate::grpc_output::take_broker_phases();
                        crate::grpc_output::take_admission_ledger();
                        crate::grpc_output::take_handoffs();
                        crate::grpc_output::take_first_queue_ticks();
                        crate::grpc_output::take_deliveries();
                    }
                    let progression = if workflow.predecessors.is_empty() {
                        None
                    } else {
                        Some(ledger.prepare_workflow_candidate(&workflow.predecessors, &plan, workflow.observed.as_deref())?)
                    };
                    #[cfg(test)]
                    let broker_started = std::time::Instant::now();
                    let execution = weaver_broker::execute_provider_progression(

                        &mut ledger,
                        weaver_broker::ProviderExecution {
                            plan: &plan,
                            transport: &transport,
                            format: if arrow { "arrow" } else { "protobuf" },
                            batch_rows: batch_rows as usize,
                        },
                        &mut output,
                        weaver_broker::ProviderExecutionAdmission {
                            authority: weaver_broker::ProviderExecutionAuthority {
                                catalog: &catalog,
                                oauth: oauth.as_ref(),
                            },
                            progression: progression.as_ref(),
                        },
                    );
                    #[cfg(test)]
                    {
                        weaver_ledger::persistence::use_cached_currentness_plans(false);
                        weaver_ledger::use_locked_publication_review(false);
                        weaver_ledger::use_locked_original_evidence(false);
                        weaver_ledger::use_fresh_provider_domain_plan(false);
                        weaver_ledger::use_separate_release_reads(false);
                        weaver_ledger::use_cached_release_programs(false);
                        weaver_ledger::use_early_admission_barrier(false);
                        weaver_ledger::use_exclusive_provider_reads(false);
                        weaver_ledger::use_full_lifecycle_invalidation(false);
                        weaver_ledger::use_conservative_range_invalidation(false);
                    }
                    #[cfg(test)]
                    if std::env::var_os("WEAVER_TEST_PROVIDER_TIMINGS").is_some() {
                        let t = ledger.transaction_timings();
                        eprintln!(
                            "weaver-oauth-timing {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {} {}",
                            t.provider_oauth_check.nanos,
                            t.domain_hold.nanos,
                            t.transaction_hold.nanos,
                            t.provider_request.nanos,
                            t.provider_queue.nanos,
                            t.provider_oauth_prepare.nanos,
                            t.transaction_begin.nanos,
                            t.commit.nanos,
                            t.domain_wait.nanos,
                            t.domain_keys.nanos,
                            t.provider_domain.nanos,
                            t.provider_pending.nanos.saturating_add(t.provider_review.nanos).saturating_add(t.provider_birth.nanos),
                            t.provider_profile.nanos,
                            t.provider_claim.nanos,
                            t.provider_cedar.nanos,
                            t.rollback.nanos,
                            t.provider_pending.nanos,
                            t.provider_review.nanos,
                            t.provider_birth.nanos,
                            t.provider_publication_prepare.nanos,
                            t.provider_original.nanos,
                            t.provider_manifest.nanos,
                            t.provider_history.nanos,
                            t.provider_original_prepare.nanos,
                            open_nanos,
                            t.provider_domain_prepare.nanos,
                            t.provider_domain.attempts
                        );
                    }
                    #[cfg(test)]
                    if std::env::var_os("WEAVER_TEST_PROVIDER_TAIL").is_some() {
                        let t = ledger.transaction_timings();
                        eprintln!(
                            "weaver-provider-tail {} {} {} {} {} {} {}",
                            plan.family,
                            worker_started.duration_since(queued_at).as_nanos(),
                            worker_started.elapsed().as_nanos(),
                            t.domain_wait.nanos,
                            t.domain_hold.nanos,
                            t.commit.nanos,
                            t.provider_domain.nanos,
                        );
                    }
                    #[cfg(test)]
                    if trace_scopes {
                        eprintln!("weaver-provider-encode {} {}", plan.family, crate::grpc_output::take_encoding_nanos());
                        use std::fmt::Write;
                        let transport_phases = crate::grpc_output::take_transport();
                        if let Some((phases, _)) = transport_phases {
                            let mut line = format!("weaver-provider-transport {}", plan.family);
                            for stage in [phases.connect, phases.tls, phases.write, phases.headers] {
                                let _ = write!(line, " {}:{}:{}", stage.nanos, u8::from(stage.attempted), u8::from(stage.completed));
                            }
                            eprintln!("{line}");
                        }

                        ledger.finish_provider_scope_trace();
                        let mut handoff = format!("weaver-provider-handoff {}", plan.family);
                        let handoffs = crate::grpc_output::take_handoffs();
                        let admission_ledger = crate::grpc_output::take_admission_ledger();
                        if let (Some(queued), Some((phases, headers)), Some(first), Some(admission_ledger)) =
                            (queued_ticks, transport_phases, crate::grpc_output::take_first_queue_ticks(), admission_ledger)
                        {
                            let [connect, tls, write, response_head] =
                                [phases.connect, phases.tls, phases.write, phases.headers]
                                    .map(|stage| u128::from(stage.nanos));
                            let write_transport = connect + tls + write;
                            let transport = write_transport + response_head;
                            let [enqueue, consume, prepare, dispatch] =
                                crate::grpc_output::take_broker_phases();
                            let mut first_frame = format!(
                                "weaver-provider-first-frame {} {} {queued} {} {} {headers} {first} {transport} {enqueue} {consume} {prepare} {dispatch} {write_transport} {open_nanos} {} {connect} {tls} {write} {response_head}",
                                plan.family,
                                plan.node,
                                worker_started.duration_since(queued_at).as_nanos(),
                                broker_started.duration_since(worker_started).as_nanos(),
                                u8::from(reused),
                            );
                            crate::grpc_output::append_admission_ledger(&mut first_frame, admission_ledger);
                            eprintln!("{first_frame}");
                        }
                        for (sequence, time) in handoffs {
                            let _ = write!(handoff, " {sequence}:{time}");
                        }
                        eprintln!("{handoff}");
                        let mut delivery = format!("weaver-provider-delivery {}", plan.family);
                        for row in crate::grpc_output::take_deliveries() {
                            let _ = write!(delivery," {}:{}:{}:{}:{}:{}", row.first, row.acknowledged_unix_nanos,
                                row.accepted_unix_nanos, row.lock_wait_nanos, row.turn_nanos, row.refresh_count);
                        }
                        eprintln!("{delivery}");

                    }
                    #[cfg(test)]
                    if reuse && execution.is_ok() && !output.cancelled.is_cancelled() {
                        custody.park_provider(ledger, &output.shutdown);
                    }
                    execution
                })();
                output.telemetry.record(if result.is_ok() {
                    weaver_telemetry::Signal::ProviderCompleted
                } else {
                    weaver_telemetry::Signal::ProviderFailed
                });
                // A duplicate root request may prompt reconciliation. Only
                // the durable release and current guards can admit an edge.
                if (result.is_ok() || session_root)
                    && let Some(wakeup) = wakeup
                {
                    wakeup.notify_one();
                }
                if let Err(error) = &result {
                    let _ = sender.try_send(Err(Status::failed_precondition(format!(
                        "provider execution not completed; inspect original operation: {}",
                        crate::grpc_contracts::rejection_reason(error),
                    ))));
                }
                result
            })
            .map_err(|_| Status::unavailable("native admission closed"))?;
        self.runtime
            .telemetry()
            .record(weaver_telemetry::Signal::ProviderAdmitted);
        drop(job); // The runtime tracker, not the disconnected caller, owns completion.
        Ok(ResponseStream::new(
            receiver,
            cursor,
            cancelled,
            self.runtime.cancellation(),
        ))
    }
}
