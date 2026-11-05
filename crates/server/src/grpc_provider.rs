// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Provider RPC lifecycle; source publication and server transport stay separate.
use crate::grpc::{Gateway, ResponseStream};
use crate::grpc_contracts::{plan, status};
use crate::{grpc_output::Output, pb, rpc_security::RpcRole};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tonic::{Request, Response, Status};
use weaver_ledger::Ledger;

impl Gateway {
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
                    let trace_scopes = std::env::var_os("WEAVER_TEST_PROVIDER_SCOPE_TRACE").is_some();
                    #[cfg(test)]
                    if trace_scopes {
                        ledger.trace_provider_scopes(&plan.family);
                    }
                    #[cfg(test)]
                    weaver_ledger::use_cached_release_programs(
                        std::env::var("WEAVER_TEST_CACHED_RELEASE_PROGRAMS").as_deref() == Ok("1"),
                    );
                    #[cfg(test)]
                    {
                        crate::grpc_output::take_encoding_nanos();
                        crate::grpc_output::take_handoffs();
                        crate::grpc_output::take_deliveries();
                    }
                    let execution = weaver_broker::execute_catalog_provider_with_oauth(

                        &mut ledger,
                        weaver_broker::ProviderExecution {
                            plan: &plan,
                            transport: &transport,
                            format: if arrow { "arrow" } else { "protobuf" },
                            batch_rows: request.batch_rows as usize,
                        },
                        &mut output,
                        weaver_broker::ProviderExecutionAuthority {
                            catalog: &request.catalog_version,
                            oauth: oauth.as_ref(),
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
                        ledger.finish_provider_scope_trace();
                        let mut handoff = format!("weaver-provider-handoff {}", plan.family);
                        for (sequence, time) in crate::grpc_output::take_handoffs() {
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
                    execution
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
        Ok(Response::new(ResponseStream::new(
            receiver,
            cursor,
            cancelled,
            self.runtime.cancellation(),
        )))
    }
}
