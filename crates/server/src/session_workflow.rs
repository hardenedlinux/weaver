// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Resume the sealed Session path from the durable provider frontier.
use crate::{
    grpc::Gateway,
    grpc_provider::{StreamSettings, WorkflowAdmission},
};
use std::{collections::BTreeSet, sync::Arc};
use tokio_stream::StreamExt;
use weaver_contracts::{Error, ProviderPlan, ProviderState, Result};
use weaver_ledger::{Ledger, WorkflowObservation};

struct SessionStep {
    admission: WorkflowAdmission,
    next: ProviderPlan,
    catalog: String,
}

enum SessionWork {
    Linear(Vec<SessionStep>),
    Graph(Box<SessionGraph>),
}

struct SessionGraph {
    plans: Vec<ProviderPlan>,
    cut: WorkflowObservation,
    catalog: String,
    edges: Vec<(String, String)>,
}

impl Gateway {
    pub(crate) async fn run_session_workflow(&self) {
        let Some(wakeup) = self.runtime.session_wakeup() else {
            return;
        };
        let mut running = BTreeSet::new();
        let mut deferred = BTreeSet::new();
        let mut streams = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                biased;
                _ = self.runtime.cancellation() => return,
                result = streams.join_next(), if !streams.is_empty() => {
                    let Some(Ok(node)) = result else { return };
                    running.remove(&node);
                    if deferred.remove(&node) {
                        wakeup.notify_one();
                    }
                    continue;
                }
                _ = wakeup.notified() => {}
            }
            let Some(slot) = self.session_slot().await else {
                return;
            };
            let gateway = self.clone();
            let Ok(job) = self
                .runtime
                .spawn_blocking(slot, move |_| gateway.session_observation())
            else {
                return;
            };
            let Ok(Ok(Some(batch))) = job.await else {
                continue;
            };
            let steps = match batch {
                SessionWork::Linear(steps) => steps,
                SessionWork::Graph(graph) => match self.derive_session_steps(*graph).await {
                    Ok(steps) => steps,
                    Err(_) => continue,
                },
            };
            for step in steps {
                let node = step.next.node.clone();
                if running.contains(&node) {
                    deferred.insert(node);
                    continue;
                }
                let Some(slot) = self.session_slot().await else {
                    break;
                };
                let Ok(mut response) = self.start_provider_stream(
                    slot,
                    step.next,
                    step.admission,
                    None,
                    StreamSettings {
                        arrow: false,
                        batch_rows: 1,
                        catalog: step.catalog,
                    },
                ) else {
                    continue;
                };
                running.insert(node.clone());
                streams.spawn(async move {
                    // Poll the existing guarded receiver. The release stays
                    // local to the Session; durable receipts remain inspectable.
                    while let Some(Ok(_)) = response.next().await {}
                    node
                });
            }
        }
    }

    async fn session_slot(&self) -> Option<Arc<tokio::sync::OwnedSemaphorePermit>> {
        tokio::select! {
            biased;
            _ = self.runtime.cancellation() => None,
            slot = self.admission.session_execution() => slot,
        }
    }

    async fn derive_session_steps(&self, graph: SessionGraph) -> Result<Vec<SessionStep>> {
        let SessionGraph {
            plans,
            cut,
            edges,
            catalog,
        } = graph;
        let nodes = plans.iter().map(|plan| plan.node.clone()).collect();
        let ready = self
            .runtime
            .governor()?
            .derive(weaver_governance::GovernorCut {
                nodes,
                edges: edges.clone(),
                complete: cut.complete.clone(),
                available: cut.available.clone(),
                pending: cut.pending.clone(),
                nested_selectors: cut
                    .nested
                    .as_ref()
                    .map(|n| n.selectors.clone())
                    .unwrap_or_default(),
                nested_results: cut
                    .nested
                    .as_ref()
                    .map(|n| n.results.clone())
                    .unwrap_or_default(),
                nested_decisions: cut
                    .nested
                    .as_ref()
                    .map(|n| n.decisions.clone())
                    .unwrap_or_default(),
                choice_arms: cut
                    .choice
                    .as_ref()
                    .map(|choice| choice.arms.to_vec())
                    .unwrap_or_default(),
                choice_join: cut
                    .choice
                    .iter()
                    .map(|choice| choice.join.clone())
                    .collect(),
                choice_result: cut
                    .choice
                    .iter()
                    .filter_map(|choice| choice.route.map(|route| route.as_str().to_owned()))
                    .collect(),
                choice_decided: cut
                    .choice
                    .iter()
                    .filter_map(|choice| choice.decided.clone())
                    .collect(),
            })
            .await
            .map_err(|_| Error::Conflict("Scheme Governor derivation unavailable"))?;
        let mut ready = std::collections::BTreeSet::from_iter(ready);
        let cut = Arc::new(cut);
        let mut steps = Vec::new();
        for next in &plans {
            if !ready.remove(&next.node) {
                continue;
            }
            let predecessors = edges
                .iter()
                .filter(|(child, parent)| {
                    child == &next.node
                        && cut.nested.as_ref().is_none_or(|nested| {
                            nested
                                .predecessors
                                .get(child)
                                .is_some_and(|parents| parents.contains(parent))
                        })
                        && cut.choice.as_ref().is_none_or(|choice| {
                            child != &choice.join || choice.decided.as_ref() == Some(parent)
                        })
                })
                .map(|(_, parent)| {
                    plans
                        .iter()
                        .find(|plan| &plan.node == parent)
                        .cloned()
                        .ok_or(Error::Conflict("Session predecessor missing"))
                })
                .collect::<Result<Vec<_>>>()?;
            if predecessors.is_empty() || !cut.pending.contains(&next.node) {
                return Err(Error::Conflict("invalid Scheme Governor candidate"));
            }
            steps.push(SessionStep {
                admission: WorkflowAdmission {
                    predecessors,
                    observed: Some(cut.clone()),
                },
                next: next.clone(),
                catalog: catalog.clone(),
            });
        }
        if !ready.is_empty() {
            return Err(Error::Conflict("foreign Scheme Governor candidate"));
        }
        Ok(steps)
    }

    fn session_observation(&self) -> Result<Option<SessionWork>> {
        let Some(feed) = self.runtime.fact_feed() else {
            return Ok(None);
        };
        let Some(source) = self
            .runtime
            .single_provider()
            .filter(|lifecycle| lifecycle.activated())
            .and_then(|lifecycle| lifecycle.ready.get())
            .map(crate::single_provider::Prepared::source)
        else {
            return Ok(None);
        };
        let mut ledger = Ledger::open(&self.config.database)?;
        // Activation and fact-resolution wakes can arrive during the root
        // stream. Only a complete root can produce a DAG successor. Avoid
        // taking the family authority cut while its first response is live.
        // Durable completion emits another wake; admission still rechecks it.
        if feed.workflow_dag
            && ledger
                .provider_receipt(&feed.family, &feed.root)?
                .is_none_or(|receipt| receipt.state != ProviderState::Complete)
        {
            return Ok(None);
        }
        let plans = feed
            .workflow_path
            .iter()
            .map(|node| {
                source
                    .plans()
                    .iter()
                    .find(|plan| plan.family == feed.family && plan.node == *node)
                    .cloned()
                    .ok_or(Error::Conflict("compiled Session plan missing"))
            })
            .collect::<Result<Vec<_>>>()?;
        let catalog = ledger
            .provider_catalog()?
            .map(|(version, _)| version)
            .unwrap_or_default();
        if feed.workflow_dag {
            static TIMING: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
            let started = TIMING
                .get_or_init(|| std::env::var_os("WEAVER_TEST_GOVERNOR_TIMING").is_some())
                .then(std::time::Instant::now);
            let cut = ledger.observe_workflow(&plans)?;
            if let Some(started) = started {
                eprintln!(
                    "weaver-governor-observe ledger_ns={}",
                    started.elapsed().as_nanos()
                );
            }
            return Ok(Some(SessionWork::Graph(Box::new(SessionGraph {
                plans,
                cut,
                catalog,
                edges: feed.dependencies.clone(),
            }))));
        }
        let mut previous = None;
        for current in plans {
            let receipt = ledger.provider_receipt(&current.family, &current.node)?;
            match receipt {
                Some(receipt) if receipt.digest != current.digest()? => {
                    return Err(Error::Conflict(
                        "Session claim differs from compiled original",
                    ));
                }
                Some(receipt) if receipt.state == ProviderState::Complete => {
                    previous = Some(current)
                }
                Some(receipt) if receipt.state == ProviderState::Unknown => return Ok(None),
                _ => {
                    return Ok(previous.map(|previous| {
                        SessionWork::Linear(vec![SessionStep {
                            admission: WorkflowAdmission {
                                predecessors: vec![previous],
                                observed: None,
                            },
                            next: current,
                            catalog,
                        }])
                    }));
                }
            }
        }
        Ok(None)
    }
}
