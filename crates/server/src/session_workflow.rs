// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Resume the sealed Session path from the durable provider frontier.
use crate::{
    grpc::Gateway,
    grpc_provider::{StreamSettings, WorkflowAdmission},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Arc,
};
use tokio_stream::StreamExt;
use weaver_contracts::{Error, FactFeed, ProviderPlan, ProviderState, Result};
use weaver_governance::{GovernorCut, GovernorTopology};
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
    topology: Arc<SessionTopology>,
    cut: WorkflowObservation,
    catalog: String,
}

/// Immutable bindings from the compiled original and its deployed fact feed.
pub(crate) struct SessionTopology {
    plans: Vec<ProviderPlan>,
    by_node: BTreeMap<String, usize>,
    predecessors: Vec<Vec<usize>>,
    governor: Arc<GovernorTopology>,
}

impl SessionTopology {
    pub(crate) fn prepare(feed: &FactFeed, plans: &[ProviderPlan]) -> Result<Self> {
        let plans = feed
            .workflow_path
            .iter()
            .map(|node| {
                plans
                    .iter()
                    .find(|plan| plan.family == feed.family && plan.node == *node)
                    .cloned()
                    .ok_or(Error::Conflict("compiled Session plan missing"))
            })
            .collect::<Result<Vec<_>>>()?;
        let by_node: BTreeMap<_, _> = plans
            .iter()
            .enumerate()
            .map(|(index, plan)| (plan.node.clone(), index))
            .collect();
        let mut predecessors = vec![Vec::new(); plans.len()];
        if feed.workflow_dag {
            for (child, parent) in &feed.dependencies {
                let child = by_node
                    .get(child)
                    .ok_or(Error::Conflict("compiled Session child missing"))?;
                let parent = by_node
                    .get(parent)
                    .ok_or(Error::Conflict("Session predecessor missing"))?;
                predecessors[*child].push(*parent);
            }
        }
        Ok(Self {
            plans,
            by_node,
            predecessors,
            governor: Arc::new(GovernorTopology {
                nodes: feed.workflow_path.clone(),
                edges: feed.dependencies.clone(),
                choice_arms: feed
                    .choice_nodes()
                    .map(|nodes| nodes[1..3].to_vec())
                    .unwrap_or_default(),
                choice_join: feed
                    .choice_nodes()
                    .iter()
                    .map(|nodes| nodes[3].clone())
                    .collect(),
                nested_selectors: feed.workflow_selectors.clone(),
            }),
        })
    }

    pub(crate) async fn preopen(&self, governor: &weaver_governance::SourceClient) {
        let started = governor_timing().then(std::time::Instant::now);
        if started.is_some() {
            eprintln!("weaver-governor-preopen begin");
        }
        // This empty input initializes relations but proposes no executable
        // step. The first live wake supplies the complete ledger observation.
        let reply = governor
            .derive(GovernorCut {
                topology: self.governor.clone(),
                complete: Vec::new(),
                available: Vec::new(),
                pending: Vec::new(),
                choice_result: Vec::new(),
                choice_decided: Vec::new(),
                nested_results: Vec::new(),
                nested_decisions: Vec::new(),
            })
            .await;
        let ready = matches!(reply, Ok(weaver_governance::DerivationOutput::Indices(indices)) if indices.is_empty());
        if let Some(started) = started {
            eprintln!(
                "weaver-governor-preopen end ok={ready} elapsed_ns={}",
                started.elapsed().as_nanos()
            );
        }
    }
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
        let started = governor_timing().then(std::time::Instant::now);
        let SessionGraph {
            topology,
            cut,
            catalog,
        } = graph;
        let graph = &topology.governor;
        let observed_selectors = cut
            .nested
            .as_ref()
            .map_or(&[][..], |nested| nested.selectors.as_slice());
        let observed_arms = cut
            .choice
            .as_ref()
            .map_or(&[][..], |choice| choice.arms.as_slice());
        let observed_join = cut
            .choice
            .as_ref()
            .map_or(&[][..], |choice| std::slice::from_ref(&choice.join));
        if graph.nested_selectors != observed_selectors
            || graph.choice_arms != observed_arms
            || graph.choice_join != observed_join
        {
            return Err(Error::Conflict("Session Governor topology changed"));
        }
        let request = GovernorCut {
            topology: graph.clone(),
            complete: cut.complete.clone(),
            available: cut.available.clone(),
            pending: cut.pending.clone(),
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
        };
        let governor = self.runtime.governor()?;
        let submitted = started.map(|_| std::time::Instant::now());
        let ready = governor
            .derive(request)
            .await
            .map_err(|_| Error::Conflict("Scheme Governor derivation unavailable"))?;
        let received = started.map(|_| std::time::Instant::now());
        // Keep the compiled path order for admission regardless of the order
        // returned by Scheme, including repeated candidate identities.
        let mut ready = match ready {
            weaver_governance::DerivationOutput::Nodes(nodes) => nodes
                .iter()
                .map(|node| {
                    topology
                        .by_node
                        .get(node)
                        .copied()
                        .ok_or(Error::Conflict("foreign Scheme Governor candidate"))
                })
                .collect::<Result<Vec<_>>>()?,
            weaver_governance::DerivationOutput::Indices(indices) => indices,
            weaver_governance::DerivationOutput::Source(_) => {
                return Err(Error::Conflict("Governor result kind"));
            }
        };
        ready.sort_unstable();
        ready.dedup();
        let cut = Arc::new(cut);
        let mut steps = Vec::with_capacity(ready.len());
        for index in ready {
            let next = topology
                .plans
                .get(index)
                .ok_or(Error::Conflict("foreign Scheme Governor candidate"))?;
            let predecessors: Vec<_> = topology.predecessors[index]
                .iter()
                .map(|&parent| &topology.plans[parent])
                .filter(|parent| {
                    cut.nested.as_ref().is_none_or(|nested| {
                        nested
                            .predecessors
                            .get(&next.node)
                            .is_some_and(|parents| parents.contains(&parent.node))
                    }) && cut.choice.as_ref().is_none_or(|choice| {
                        next.node != choice.join || choice.decided.as_ref() == Some(&parent.node)
                    })
                })
                .cloned()
                .collect();
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
        if let (Some(started), Some(submitted), Some(received)) = (started, submitted, received) {
            let finished = std::time::Instant::now();
            eprintln!(
                "weaver-governor-resolve elapsed_ns={} prepare_ns={} roundtrip_ns={} validate_ns={}",
                finished.duration_since(started).as_nanos(),
                submitted.duration_since(started).as_nanos(),
                received.duration_since(submitted).as_nanos(),
                finished.duration_since(received).as_nanos(),
            );
        }
        Ok(steps)
    }

    fn session_observation(&self) -> Result<Option<SessionWork>> {
        let Some(feed) = self.runtime.fact_feed() else {
            return Ok(None);
        };
        let Some(topology) = self
            .runtime
            .single_provider()
            .filter(|lifecycle| lifecycle.activated())
            .and_then(|lifecycle| lifecycle.ready.get())
            .and_then(crate::single_provider::Prepared::session)
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
        let catalog = ledger
            .provider_catalog()?
            .map(|(version, _)| version)
            .unwrap_or_default();
        if feed.workflow_dag {
            let started = governor_timing().then(std::time::Instant::now);
            let cut = ledger.observe_workflow(&topology.plans)?;
            if let Some(started) = started {
                eprintln!(
                    "weaver-governor-observe ledger_ns={}",
                    started.elapsed().as_nanos()
                );
            }
            return Ok(Some(SessionWork::Graph(Box::new(SessionGraph {
                topology: topology.clone(),
                cut,
                catalog,
            }))));
        }
        let mut previous = None;
        for current in &topology.plans {
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
                                predecessors: vec![ProviderPlan::clone(previous)],
                                observed: None,
                            },
                            next: current.clone(),
                            catalog,
                        }])
                    }));
                }
            }
        }
        Ok(None)
    }
}

fn governor_timing() -> bool {
    static TIMING: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *TIMING.get_or_init(|| std::env::var_os("WEAVER_TEST_GOVERNOR_TIMING").is_some())
}
