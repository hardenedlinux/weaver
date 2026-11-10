// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Conditional branch evidence, bound to the existing release and winner transactions.
use crate::{
    persistence::{WriteScope, exec, maybe_current, params},
    store::{db, integer},
};
use serde::{Deserialize, Serialize};
use weaver_contracts::{
    Error, MAX_WORKFLOW_RESULT_BYTES, ProviderPlan, Result, WorkflowRoute, body_digest, decode,
};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ResultDocument {
    route: WorkflowRoute,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ReleasedChoice {
    pub(crate) route: WorkflowRoute,
    pub(crate) response_digest: String,
    pub(crate) plan_digest: String,
    pub(crate) released_events: u64,
}

#[derive(PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ChoiceDecision {
    pub(crate) result: ReleasedChoice,
    pub(crate) arm: String,
    pub(crate) arm_digest: String,
    pub(crate) floor: u64,
    pub(crate) snapshot: String,
}

#[derive(PartialEq, Eq)]
pub(crate) enum ChoiceBasis {
    Admit(ChoiceDecision),
    Retain(ChoiceDecision),
}

/// The selector's complete result and any durable decision at the observed cut.
pub struct WorkflowChoiceObservation {
    pub arms: [String; 2],
    pub join: String,
    pub route: Option<WorkflowRoute>,
    pub decided: Option<String>,
}

pub(crate) fn record_result(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    released_events: u64,
    response: &str,
) -> Result<()> {
    if response.len() > MAX_WORKFLOW_RESULT_BYTES || released_events == 0 {
        return Ok(());
    }
    let Ok(ResultDocument { route }) = serde_json::from_str(response) else {
        return Ok(());
    };
    if !crate::hard_fact::is_workflow_selector(tx, &plan.family, &plan.node)? {
        return Err(Error::Conflict("workflow result from another node"));
    }
    let result = ReleasedChoice {
        route,
        response_digest: body_digest(response),
        plan_digest: plan.digest()?,
        released_events,
    };
    exec(
        tx,
        "INSERT INTO main.provider_terminal_results VALUES(?1,?2,?3)",
        params![
            plan.family.clone(),
            plan.node.clone(),
            serde_json::to_string(&result)?
        ],
    )
    .map_err(db)?;
    Ok(())
}

pub(crate) fn read_result(
    tx: &WriteScope<'_>,
    family: &str,
    selector: &str,
) -> Result<Option<ReleasedChoice>> {
    let terminal = maybe_current(
        tx,
        "SELECT result.record, run.digest, run.next_event FROM main.provider_terminal_results result
         JOIN main.provider_runs run ON run.family=result.family AND run.node=result.node
         WHERE run.family=?1 AND run.node=?2 AND run.state='complete' AND run.dispatched=2
           AND NOT EXISTS(SELECT 1 FROM main.provider_releases release
                          WHERE release.family=run.family AND release.node=run.node
                            AND release.state!='released')",
        params![family.to_owned(), selector.to_owned()],
        |row| Ok((row.get::<String>(0)?, row.get::<String>(1)?, integer(row, 2)?)),
    ).map_err(db)?;
    terminal
        .map(|(record, digest, events)| {
            let result: ReleasedChoice = decode(record.as_bytes())?;
            if result.plan_digest != digest || result.released_events != events || events == 0 {
                return Err(Error::Conflict(
                    "workflow result no longer binds the complete release",
                ));
            }
            Ok(result)
        })
        .transpose()
}

pub(crate) fn read_decision(
    tx: &WriteScope<'_>,
    origin: &str,
    selector: &str,
    arms: [&str; 2],
    result: Option<&ReleasedChoice>,
    nested: bool,
) -> Result<Option<ChoiceDecision>> {
    let query = if nested {
        "SELECT arm_digest, record FROM main.provider_workflow_decisions WHERE origin=?1 AND selector=?2"
    } else {
        "SELECT successor_digest, record FROM main.provider_workflow_transitions WHERE origin=?1 AND successor=?2"
    };
    maybe_current(
        tx,
        query,
        params![origin.to_owned(), selector.to_owned()],
        |row| Ok((row.get::<String>(0)?, row.get::<String>(1)?)),
    )
    .map_err(db)?
    .map(|(digest, record)| {
        let decision: ChoiceDecision = decode(record.as_bytes())?;
        let expected = match decision.result.route {
            WorkflowRoute::Left => arms[0],
            WorkflowRoute::Right => arms[1],
        };
        if result != Some(&decision.result)
            || decision.arm != expected
            || decision.arm_digest != digest
        {
            return Err(Error::Conflict("persisted workflow choice changed"));
        }
        Ok(decision)
    })
    .transpose()
}

fn read_basis(
    tx: &WriteScope<'_>,
    family: &str,
    origin: &str,
    nodes: &[String; 4],
) -> Result<(Option<ReleasedChoice>, Option<ChoiceDecision>)> {
    let result = read_result(tx, family, &nodes[0])?;
    let decision = read_decision(
        tx,
        origin,
        &nodes[0],
        [&nodes[1], &nodes[2]],
        result.as_ref(),
        false,
    )?;
    Ok((result, decision))
}

pub(crate) fn observe(
    tx: &WriteScope<'_>,
    family: &str,
    origin: &str,
    nodes: Option<&[String; 4]>,
) -> Result<Option<WorkflowChoiceObservation>> {
    let Some(nodes) = nodes else {
        return Ok(None);
    };
    let (result, decision) = read_basis(tx, family, origin, nodes)?;
    let [_, left, right, join] = nodes.clone();
    Ok(Some(WorkflowChoiceObservation {
        arms: [left, right],
        join,
        route: result.map(|r| r.route),
        decided: decision.map(|d| d.arm),
    }))
}

pub(crate) fn prepare(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    origin: &str,
    expected: &mut Vec<String>,
    floor: u64,
    snapshot: &str,
) -> Result<Option<ChoiceBasis>> {
    let Some(nodes) = crate::hard_fact::choice_nodes(tx, &plan.family)? else {
        return Ok(None);
    };
    let (result, decision) = read_basis(tx, &plan.family, origin, &nodes)?;
    if plan.node == nodes[3] {
        let decision = decision.ok_or(Error::Conflict("workflow choice is uncommitted"))?;
        expected.retain(|parent| parent == &decision.arm);
        return Ok(Some(ChoiceBasis::Retain(decision)));
    }
    let result = result.ok_or(Error::Conflict(
        "workflow selector has no complete structured result",
    ))?;
    if plan.node != result.route.arm(&nodes) {
        return Err(Error::Conflict("workflow arm was not selected"));
    }
    let arm_digest = plan.digest()?;
    let basis = match decision {
        Some(decision) if decision.arm_digest == arm_digest => ChoiceBasis::Retain(decision),
        Some(_) => return Err(Error::Conflict("workflow arm identity changed")),
        None => ChoiceBasis::Admit(ChoiceDecision {
            result,
            arm: plan.node.clone(),
            arm_digest,
            floor,
            snapshot: snapshot.to_owned(),
        }),
    };
    Ok(Some(basis))
}

pub(crate) fn bind(
    tx: &WriteScope<'_>,
    origin: &str,
    selector: &str,
    decision: &ChoiceDecision,
) -> Result<()> {
    exec(
        tx,
        "INSERT INTO main.provider_workflow_transitions VALUES(?1,?2,?3,?4)",
        params![
            origin.to_owned(),
            selector.to_owned(),
            decision.arm_digest.clone(),
            serde_json::to_string(decision)?
        ],
    )
    .map_err(db)?;
    Ok(())
}

pub(crate) fn require(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    origin: &str,
    digest: &str,
) -> Result<()> {
    let nodes = crate::hard_fact::choice_nodes(tx, &plan.family)?;
    require_in_choice(tx, plan, origin, digest, nodes.as_ref())
}

pub(crate) fn require_in_choice(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    origin: &str,
    digest: &str,
    nodes: Option<&[String; 4]>,
) -> Result<()> {
    let Some(nodes) = nodes else {
        return Ok(());
    };
    let (_, decision) = read_basis(tx, &plan.family, origin, nodes)?;
    let decision = decision.ok_or(Error::Conflict("workflow choice is uncommitted"))?;
    if plan.node == nodes[3] {
        let valid: bool = crate::persistence::one_current(
            tx,
            "SELECT EXISTS(SELECT 1 FROM main.provider_workflow_transitions WHERE origin=?1 AND successor=?2 AND successor_digest=?3)",
            params![origin.to_owned(), decision.arm, decision.arm_digest],
            |row| row.get(0),
        ).map_err(db)?;
        if !valid {
            return Err(Error::Conflict("selected workflow arm claim missing"));
        }
    } else if plan.node != decision.arm || digest != decision.arm_digest {
        return Err(Error::Conflict(
            "workflow arm differs from committed decision",
        ));
    }
    Ok(())
}

impl ChoiceBasis {
    pub(crate) fn verify_join(&self, predecessors: &[ProviderPlan]) -> Result<()> {
        if let (Self::Retain(decision), [predecessor]) = (self, predecessors)
            && predecessor.node == decision.arm
            && predecessor.digest()? != decision.arm_digest
        {
            return Err(Error::Conflict(
                "join predecessor differs from selected claim",
            ));
        }
        Ok(())
    }
}
