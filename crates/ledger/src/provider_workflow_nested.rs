// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Reconstruct active incoming edges from the deployed graph and durable selector decisions.
use crate::{
    persistence::{WriteScope, exec, params},
    provider_workflow_choice::{ChoiceDecision, ReleasedChoice, read_decision, read_result},
    store::db,
};
use std::collections::BTreeMap;
use weaver_contracts::{Error, FactFeed, ProviderPlan, Result, WorkflowRoute};

/// Complete selector observations and the active predecessors of eligible nodes.
pub struct NestedObservation {
    pub selectors: Vec<[String; 3]>,
    pub results: Vec<(String, String)>,
    pub decisions: Vec<(String, String)>,
    pub predecessors: BTreeMap<String, Vec<String>>,
}

#[derive(PartialEq, Eq)]
pub(crate) struct NestedDraft {
    selector: String,
    decision: ChoiceDecision,
}

struct Selector<'a> {
    nodes: &'a [String; 3],
    result: Option<ReleasedChoice>,
    decision: Option<ChoiceDecision>,
}
impl Selector<'_> {
    fn matches(&self, node: &str) -> bool {
        self.result.as_ref().is_some_and(|result| {
            node == match result.route {
                WorkflowRoute::Left => &self.nodes[1],
                WorkflowRoute::Right => &self.nodes[2],
            }
        })
    }
}

#[derive(Default, Clone, Copy)]
struct Reach {
    active: bool,
    unresolved: bool,
}

type SelectorDrafts = BTreeMap<String, (String, ReleasedChoice)>;

fn load(
    tx: &WriteScope<'_>,
    family: &str,
    origin: &str,
    graph: &weaver_contracts::FactFeed,
) -> Result<(NestedObservation, SelectorDrafts)> {
    let mut selectors = Vec::new();
    let mut gates = BTreeMap::new();
    let mut results = Vec::new();
    let mut decisions = Vec::new();
    for nodes @ [selector, left, right] in &graph.workflow_selectors {
        let result = read_result(tx, family, selector)?;
        let decision = read_decision(tx, origin, selector, [left, right], result.as_ref(), true)?;
        if let Some(result) = &result {
            results.push((selector.clone(), result.route.as_str().to_owned()));
        }
        if let Some(decision) = &decision {
            if crate::provider::receipt(tx, family, &decision.arm)?
                .is_none_or(|receipt| receipt.digest != decision.arm_digest)
            {
                return Err(Error::Conflict(
                    "nested selector decision has no selected claim",
                ));
            }
            decisions.push((selector.clone(), decision.result.route.as_str().to_owned()));
        }
        gates.insert(left.as_str(), selectors.len());
        gates.insert(right.as_str(), selectors.len());
        selectors.push(Selector {
            nodes,
            result,
            decision,
        });
    }
    let mut states = BTreeMap::from([(
        graph.root.as_str(),
        Reach {
            active: true,
            unresolved: false,
        },
    )]);
    let mut predecessors = BTreeMap::new();
    let mut drafts = BTreeMap::new();
    for node in graph.workflow_path.iter().skip(1) {
        let selector = gates.get(node.as_str()).map(|&index| &selectors[index]);
        let (reach, parents) =
            active_parents(node, &graph.dependencies, &states, selector, &mut drafts)?;
        if (!reach.unresolved || drafts.contains_key(node)) && !parents.is_empty() {
            predecessors.insert(node.clone(), parents);
        }
        states.insert(node.as_str(), reach);
    }
    Ok((
        NestedObservation {
            selectors: graph.workflow_selectors.clone(),
            results,
            decisions,
            predecessors,
        },
        drafts,
    ))
}

fn active_parents(
    node: &str,
    dependencies: &[(String, String)],
    states: &BTreeMap<&str, Reach>,
    selector: Option<&Selector<'_>>,
    drafts: &mut SelectorDrafts,
) -> Result<(Reach, Vec<String>)> {
    let mut reach = Reach::default();
    let mut parents = Vec::new();
    for (_, parent) in dependencies.iter().filter(|(child, _)| child == node) {
        let state = states
            .get(parent.as_str())
            .ok_or(Error::Conflict("nested topology changed"))?;
        reach.unresolved |= state.unresolved;
        if !state.active {
            continue;
        }
        if let Some(selector) = selector {
            match &selector.decision {
                Some(decision) if decision.arm != node => continue,
                Some(_) => {}
                None => {
                    reach.unresolved = true;
                    if !state.unresolved
                        && selector.matches(node)
                        && let Some(result) = &selector.result
                    {
                        drafts.insert(node.to_owned(), (parent.clone(), result.clone()));
                        parents.push(parent.clone());
                    }
                    continue;
                }
            }
        }
        parents.push(parent.clone());
        reach.active = true;
    }
    Ok((reach, parents))
}

pub(crate) fn observe(
    tx: &WriteScope<'_>,
    origin: &str,
    graph: &FactFeed,
) -> Result<Option<NestedObservation>> {
    if graph.workflow_selectors.is_empty() {
        return Ok(None);
    }
    load(tx, &graph.family, origin, graph).map(|(observed, _)| Some(observed))
}

pub(crate) fn prepare(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    origin: &str,
    expected: &mut Vec<String>,
    floor: u64,
    snapshot: &str,
) -> Result<Option<NestedDraft>> {
    let Some(graph) = crate::hard_fact::nested_feed(tx, &plan.family)? else {
        return Ok(None);
    };
    let (mut observation, mut drafts) = load(tx, &plan.family, origin, &graph)?;
    *expected = observation
        .predecessors
        .remove(&plan.node)
        .ok_or(Error::Conflict(
            "nested workflow predecessors unresolved or inactive",
        ))?;
    drafts
        .remove(&plan.node)
        .map(|(selector, result)| {
            Ok(NestedDraft {
                selector,
                decision: ChoiceDecision {
                    result,
                    arm: plan.node.clone(),
                    arm_digest: plan.digest()?,
                    floor,
                    snapshot: snapshot.to_owned(),
                },
            })
        })
        .transpose()
}

pub(crate) fn bind(tx: &WriteScope<'_>, origin: &str, draft: &NestedDraft) -> Result<()> {
    exec(
        tx,
        "INSERT INTO main.provider_workflow_decisions VALUES(?1,?2,?3,?4)",
        params![
            origin.to_owned(),
            draft.selector.clone(),
            draft.decision.arm_digest.clone(),
            serde_json::to_string(&draft.decision)?
        ],
    )
    .map_err(db)?;
    Ok(())
}

pub(crate) fn require_entry(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    origin: &str,
    digest: &str,
) -> Result<()> {
    let Some(graph) = crate::hard_fact::nested_feed(tx, &plan.family)? else {
        return Ok(());
    };
    require_in_graph(tx, plan, origin, digest, &graph)
}

pub(crate) fn require_in_graph(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    origin: &str,
    digest: &str,
    graph: &FactFeed,
) -> Result<()> {
    let Some([selector, left, right]) = graph
        .workflow_selectors
        .iter()
        .find(|[_, left, right]| left == &plan.node || right == &plan.node)
    else {
        return Ok(());
    };
    let result = read_result(tx, &plan.family, selector)?;
    if !read_decision(tx, origin, selector, [left, right], result.as_ref(), true)?
        .is_some_and(|decision| decision.arm == plan.node && decision.arm_digest == digest)
    {
        return Err(Error::Conflict(
            "nested workflow entry lacks its selector decision",
        ));
    }
    Ok(())
}
