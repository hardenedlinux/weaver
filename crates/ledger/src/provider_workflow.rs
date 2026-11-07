// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Compiled workflow edges using the existing provider claim and response outcome.
use crate::{
    Ledger,
    persistence::{WriteScope, begin_family, exec, one_current, params},
    provider_workflow_choice::{self as choice, ChoiceBasis, WorkflowChoiceObservation},
    provider_workflow_nested::{self as nested, NestedDraft, NestedObservation},
    store::{db, integer},
};
use serde::Serialize;
use weaver_contracts::{DomainStamp, Error, ProviderPlan, ProviderState, Result};

/// A prepared successor bound to the observed fact cut and complete releases.
#[derive(PartialEq, Eq)]
pub struct ProviderProgression {
    predecessors: Vec<ProviderPlan>,
    successor_digest: String,
    origin: DomainStamp,
    fact_floor: u64,
    fact_snapshot: String,
    observations: Vec<ReleasedResponse>,
    observed_winner: Option<String>,
    choice: Option<ChoiceBasis>,
    nested: Option<NestedDraft>,
}

#[derive(PartialEq, Eq, Serialize)]
struct ReleasedResponse {
    digest: String,
    reserved: u64,
    released_events: u64,
}

/// The Governor sees detached, coherent observations of the sealed plan set.
/// The cut is compared again before admitting its derived candidates.
pub struct WorkflowObservation {
    pub complete: Vec<String>,
    pub available: Vec<String>,
    pub pending: Vec<String>,
    pub choice: Option<WorkflowChoiceObservation>,
    pub nested: Option<NestedObservation>,
    floor: u64,
    snapshot: String,
}

fn released_response(
    tx: &WriteScope<'_>,
    predecessor: &ProviderPlan,
    domains: &weaver_contracts::DomainView,
) -> Result<ReleasedResponse> {
    let digest = predecessor.digest()?;
    require_winner(tx, predecessor, &digest)?;
    // The provider owner records 2 only after the actual dispatch callback.
    // The earlier burn (1) does not establish that a response was observed.
    let released_events = one_current(
        tx,
        "SELECT run.next_event FROM main.provider_runs run
         WHERE family=?1 AND node=?2 AND digest=?3 AND reserved=?4
           AND state='complete' AND dispatched=2 AND next_event>0
           AND NOT EXISTS(SELECT 1 FROM main.provider_releases release
                          WHERE release.family=run.family AND release.node=run.node
                            AND release.state!='released')",
        params![
            predecessor.family.clone(),
            predecessor.node.clone(),
            digest.clone(),
            predecessor.ceiling as i64
        ],
        |row| integer(row, 0),
    )
    .map_err(|error| match error {
        crate::persistence::Error::QueryReturnedNoRows => {
            Error::Conflict("provider response release incomplete")
        }
        other => db(other),
    })?;
    crate::execution_exposure::provider(tx, predecessor, &digest, domains, None, None)?;
    Ok(ReleasedResponse {
        digest,
        reserved: predecessor.ceiling,
        released_events,
    })
}

fn prepare(
    tx: &WriteScope<'_>,
    predecessors: &[ProviderPlan],
    successor: &ProviderPlan,
) -> Result<ProviderProgression> {
    let (mut expected, fact_floor, fact_snapshot) =
        crate::hard_fact::workflow_cut(tx, &successor.family, &successor.node)?
            .ok_or(Error::Conflict("provider workflow not admitted"))?;
    let domains = crate::domains::provider_view(tx, &successor.family)?;
    let choice = choice::prepare(
        tx,
        successor,
        &domains.stamp.origin,
        &mut expected,
        fact_floor,
        &fact_snapshot,
    )?;
    let nested = nested::prepare(
        tx,
        successor,
        &domains.stamp.origin,
        &mut expected,
        fact_floor,
        &fact_snapshot,
    )?;
    if !expected
        .iter()
        .map(String::as_str)
        .eq(predecessors.iter().map(|plan| plan.node.as_str()))
        || predecessors.iter().any(|plan| {
            plan.family != successor.family
                || plan.revision != successor.revision
                || plan.fence != successor.fence
        })
    {
        return Err(Error::Conflict("provider workflow predecessors changed"));
    }
    crate::hard_fact::require_available(tx, &successor.family, &successor.node)?;
    if let Some(basis) = &choice {
        basis.verify_join(predecessors)?;
    }
    let observations = predecessors
        .iter()
        .map(|plan| {
            crate::hard_fact::require_available(tx, &plan.family, &plan.node)?;
            released_response(tx, plan, &domains)
        })
        .collect::<Result<Vec<_>>>()?;
    let successor_digest = successor.digest()?;
    let observed_winner = crate::persistence::maybe_current(
        tx,
        "SELECT successor_digest FROM main.provider_workflow_transitions WHERE origin=?1 AND successor=?2",
        params![domains.stamp.origin.clone(), successor.node.clone()],
        |row| row.get::<String>(0),
    ).map_err(db)?;
    if observed_winner
        .as_ref()
        .is_some_and(|winner| winner != &successor_digest)
    {
        return Err(Error::Conflict("provider workflow winner changed"));
    }
    Ok(ProviderProgression {
        predecessors: predecessors.to_vec(),
        successor_digest,
        origin: domains.stamp,
        fact_floor,
        fact_snapshot,
        observations,
        observed_winner,
        choice,
        nested,
    })
}

impl Ledger {
    /// The trusted host supplies two plans from the sealed compiled original.
    /// The ledger supplies the authentic complete response observation and frontier.
    pub fn prepare_provider_progression(
        &mut self,
        predecessor: &ProviderPlan,
        successor: &ProviderPlan,
    ) -> Result<ProviderProgression> {
        self.prepare_workflow_candidate(std::slice::from_ref(predecessor), successor, None)
    }

    pub fn prepare_workflow_candidate(
        &mut self,
        predecessors: &[ProviderPlan],
        successor: &ProviderPlan,
        observed: Option<&WorkflowObservation>,
    ) -> Result<ProviderProgression> {
        let tx = begin_family(&mut self.connection, &successor.family).map_err(db)?;
        let proposal = prepare(&tx, predecessors, successor)?;
        if observed.is_some_and(|cut| {
            cut.floor != proposal.fact_floor || cut.snapshot != proposal.fact_snapshot
        }) {
            return Err(Error::Conflict("Governor observation changed"));
        }
        tx.commit().map_err(db)?;
        Ok(proposal)
    }

    pub fn observe_workflow(&mut self, plans: &[ProviderPlan]) -> Result<WorkflowObservation> {
        let [root, successor, ..] = plans else {
            return Err(Error::Invalid("Session plan set"));
        };
        let tx = begin_family(&mut self.connection, &root.family).map_err(db)?;
        let (_, floor, snapshot) =
            crate::hard_fact::workflow_cut(&tx, &root.family, &successor.node)?
                .ok_or(Error::Conflict("Session fact cut unavailable"))?;
        let domains = crate::domains::provider_view(&tx, &root.family)?;
        let mut cut = WorkflowObservation {
            complete: vec![],
            available: vec![],
            pending: vec![],
            choice: choice::observe(&tx, &root.family, &domains.stamp.origin)?,
            nested: nested::observe(&tx, &root.family, &domains.stamp.origin)?,
            floor,
            snapshot,
        };
        for plan in plans {
            match crate::hard_fact::require_available(&tx, &plan.family, &plan.node) {
                Ok(Some(_)) => cut.available.push(plan.node.clone()),
                Err(Error::Conflict(_)) => {}
                Ok(None) => return Err(Error::Conflict("Session fact scope changed")),
                Err(error) => return Err(error),
            }
            match crate::provider::receipt(&tx, &plan.family, &plan.node)? {
                Some(receipt) if receipt.digest != plan.digest()? => {
                    return Err(Error::Conflict("Session plan changed"));
                }
                Some(receipt) if receipt.state == ProviderState::Complete => {
                    released_response(&tx, plan, &domains)?;
                    cut.complete.push(plan.node.clone());
                }
                Some(receipt) if receipt.state == ProviderState::Unknown => {}
                _ => cut.pending.push(plan.node.clone()),
            }
        }
        tx.commit().map_err(db)?;
        Ok(cut)
    }
}

pub(crate) fn require_admission(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    proposal: Option<&ProviderProgression>,
) -> Result<()> {
    let governed = crate::hard_fact::workflow_cut(tx, &plan.family, &plan.node)?.is_some();
    match (governed, proposal) {
        (false, None) => Ok(()),
        (true, Some(proposal)) if prepare(tx, &proposal.predecessors, plan)? == *proposal => Ok(()),
        _ => Err(Error::Conflict("provider workflow frontier changed")),
    }
}

pub(crate) fn record_admission(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    digest: &str,
    proposal: Option<&ProviderProgression>,
    new_claim: bool,
) -> Result<()> {
    match (proposal, new_claim) {
        (Some(proposal), true) => bind_winner(tx, plan, proposal),
        (Some(_), false) => require_winner(tx, plan, digest),
        (None, _) => Ok(()),
    }
}

fn bind_winner(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    proposal: &ProviderProgression,
) -> Result<()> {
    if proposal.observed_winner.is_some() {
        return Err(Error::Conflict(
            "provider workflow frontier already advanced",
        ));
    }
    if let Some(ChoiceBasis::Admit(decision)) = &proposal.choice {
        let selector = proposal
            .predecessors
            .first()
            .ok_or(Error::Conflict("workflow selector missing"))?;
        choice::bind(tx, &proposal.origin.origin, &selector.node, decision)?;
    }
    if let Some(draft) = &proposal.nested {
        nested::bind(tx, &proposal.origin.origin, draft)?;
    }
    let basis: Vec<_> = proposal
        .predecessors
        .iter()
        .zip(&proposal.observations)
        .map(|(plan, release)| (&plan.node, release))
        .collect();
    let record = serde_json::to_string(&(
        "response-release-complete",
        basis,
        &proposal.origin,
        proposal.fact_floor,
        &proposal.fact_snapshot,
        "admitted",
    ))?;
    exec(
        tx,
        "INSERT INTO main.provider_workflow_transitions VALUES(?1,?2,?3,?4)",
        params![
            proposal.origin.origin.clone(),
            plan.node.clone(),
            proposal.successor_digest.clone(),
            record
        ],
    )
    .map_err(db)?;
    Ok(())
}

pub(crate) fn require_winner(tx: &WriteScope<'_>, plan: &ProviderPlan, digest: &str) -> Result<()> {
    if crate::hard_fact::workflow_cut(tx, &plan.family, &plan.node)?.is_some() {
        let origin = crate::domains::provider_view(tx, &plan.family)?
            .stamp
            .origin;
        let valid: bool = one_current(tx,
            "SELECT EXISTS(SELECT 1 FROM main.provider_workflow_transitions WHERE origin=?1 AND successor=?2 AND successor_digest=?3)",
            params![origin.clone(), plan.node.clone(), digest.to_owned()], |row| row.get(0)).map_err(db)?;
        if !valid {
            return Err(Error::Conflict(
                "provider successor has no committed transition",
            ));
        }
        choice::require(tx, plan, &origin, digest)?;
        nested::require_entry(tx, plan, &origin, digest)?;
    }
    Ok(())
}
