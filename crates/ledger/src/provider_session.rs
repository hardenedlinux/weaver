// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Session admission shares the original ledger; it never reserves or sends.
use crate::{
    Ledger, hard_fact,
    persistence::{self, driver::Connection},
    store::{db, integer},
};
use serde::{Deserialize, Serialize};
use weaver_contracts::{
    Error, ProviderPlan, ProviderRoute, ProviderSessionScope, ProviderTurnDerivation,
    ProviderTurnSubmission, PublicationOutcome, Result, SourceAuthority, body_digest,
};

/// Authenticated ingress supplies principal; request bytes cannot populate it.
pub struct ProviderSessionRequest {
    pub session: String,
    pub principal: String,
    pub submission: ProviderTurnSubmission,
}

/// Source-scoped discovery data. Its version is an observation, never a permit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProviderSessionCatalog {
    pub scope_commitment: String,
    pub version: String,
    pub models: Vec<String>,
    pub profile: weaver_contracts::ProviderProfile,
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BoundScope {
    authority: SourceAuthority,
    scope: ProviderSessionScope,
}
impl BoundScope {
    fn authority_digest(&self) -> Result<String> {
        Ok(body_digest(&serde_json::to_string(&self.authority)?))
    }
}

/// Observed coordinates for work outside SQL. Only a fresh transaction decides.
pub struct ProviderSessionCut {
    bound: BoundScope,
    request: ProviderSessionRequest,
    submission_digest: String,
    facts: hard_fact::UseCut,
    revision: u64,
    fence: u64,
    retained: Option<ProviderTurnDerivation>,
}
impl ProviderSessionCut {
    pub fn scope(&self) -> &ProviderSessionScope {
        &self.bound.scope
    }
    pub fn request(&self) -> &ProviderSessionRequest {
        &self.request
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn fence(&self) -> u64 {
        self.fence
    }
    /// An exact retained decision, observed without granting current use.
    /// Registration must still recheck this cut and the stored decision.
    pub fn retained_derivation(&self) -> Option<&ProviderTurnDerivation> {
        self.retained.as_ref()
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Decision {
    session: String,
    operation_id: String,
    scope_digest: String,
    authority_digest: String,
    submission_digest: String,
    family: String,
    node: String,
    task_digest: String,
    plan_digest: String,
    domains_digest: String,
}

/// Recovery retains chosen semantics. Retry bytes must match the original
/// command and plan commitments; Session metadata does not duplicate prompts.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RetainedDerivation {
    task: weaver_contracts::Task,
    domains: weaver_contracts::DomainBinding,
    model: String,
    routes: Vec<ProviderRoute>,
    ceiling: u64,
    revision: u64,
    fence: u64,
}
impl RetainedDerivation {
    fn capture(derived: &ProviderTurnDerivation) -> Self {
        Self {
            task: derived.task.clone(),
            domains: derived.domains.clone(),
            model: derived.plan.model.clone(),
            routes: derived.plan.routes.clone(),
            ceiling: derived.plan.ceiling,
            revision: derived.plan.revision,
            fence: derived.plan.fence,
        }
    }
    fn restore(self, submission: &ProviderTurnSubmission) -> Result<ProviderTurnDerivation> {
        let profile = self.task.provider_profile.as_ref().ok_or(Error::Denied)?;
        let node = self.task.nodes.first().ok_or(Error::Denied)?.clone();
        let plan = ProviderPlan {
            family: self.task.family.clone(),
            node,
            profile: self.task.profile.clone(),
            profile_commitment: profile.digest()?,
            model: self.model,
            body: submission.body.clone(),
            routes: self.routes,
            ceiling: self.ceiling,
            revision: self.revision,
            fence: self.fence,
        };
        Ok(ProviderTurnDerivation {
            task: self.task,
            domains: self.domains,
            plan,
        })
    }
}

fn read_scope(c: &Connection, session: &str) -> Result<BoundScope> {
    let (digest, record): (String, String) = persistence::maybe_current(
        c,
        "SELECT digest,record FROM provider_session_scopes WHERE session=?1",
        [session],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .map_err(db)?
    .ok_or(Error::Denied)?;
    let bound: BoundScope = weaver_contracts::decode(record.as_bytes())?;
    bound.scope.validate()?;
    if body_digest(&record) != digest || bound.scope.template.family != session {
        return Err(Error::Conflict("Session scope record changed"));
    }
    Ok(bound)
}

fn current(c: &Connection, bound: &BoundScope) -> Result<(u64, u64)> {
    if crate::source_authority::current(c)?.as_ref() != Some(&bound.authority) {
        return Err(Error::Denied);
    }
    crate::publication_barrier::require_resolved(c)?;
    let key = &bound.scope.publication;
    let receipt = crate::publication::lookup(c, &key.operation_id, &key.digest)?
        .filter(|r| r.outcome == PublicationOutcome::Committed)
        .ok_or(Error::Denied)?;
    let (revision, fence) = persistence::one_current(
        c,
        "SELECT revision,fence FROM authority WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, integer(r, 1)?)),
    )
    .map_err(db)?;
    if receipt.revision != Some(revision) || receipt.fence != Some(fence) {
        return Err(Error::Conflict("Session publication no longer current"));
    }
    Ok((revision, fence))
}

fn facts(c: &Connection, bound: &BoundScope) -> Result<hard_fact::UseCut> {
    let scope = &bound.scope;
    hard_fact::require_available(c, &scope.template.family, &scope.template.nodes[0])?
        .ok_or(Error::Conflict("Session requires parent hard facts"))
}

struct ParentRow {
    session: String,
    operation_id: String,
    node: String,
    digest: String,
    record: String,
}

/// Fact staging needs the declared graph before any conversational turn exists.
/// This does not register an unbound Task or create an execution origin.
pub(crate) fn fact_template(
    c: &Connection,
    family: &str,
    authority: &SourceAuthority,
) -> Result<Option<weaver_contracts::Task>> {
    let exists: bool = persistence::one_current(
        c,
        "SELECT EXISTS(SELECT 1 FROM provider_session_scopes WHERE session=?1)",
        [family],
        |r| r.get(0),
    )
    .map_err(db)?;
    if !exists {
        return Ok(None);
    }
    let bound = read_scope(c, family)?;
    if bound.authority != *authority {
        return Err(Error::Denied);
    }
    Ok(Some(bound.scope.template))
}

/// Resolve every Session turn back to the authenticated parent on deciding use.
/// Missing/tampered turn metadata also invalidates the original's domain digest.
pub(crate) fn parent(c: &Connection, family: &str, node: &str) -> Result<Option<String>> {
    let row: Option<ParentRow> = persistence::maybe_current(c,
        "SELECT session,operation_id,node,digest,record FROM provider_session_turns WHERE family=?1", [family],
        |r| Ok(ParentRow {session:r.get(0)?,operation_id:r.get(1)?,node:r.get(2)?,digest:r.get(3)?,record:r.get(4)?}),
    ).map_err(db)?;
    let Some(ParentRow {
        session,
        operation_id,
        node: original_node,
        digest,
        record,
    }) = row
    else {
        return Ok(None);
    };
    let bound = read_scope(c, &session)?;
    current(c, &bound)?;
    let decision: Decision = weaver_contracts::decode(record.as_bytes())?;
    if original_node != node
        || bound.scope.template.nodes != [node]
        || body_digest(&record) != digest
        || decision.session != session
        || decision.operation_id != operation_id
        || decision.family != family
        || decision.node != node
        || decision.scope_digest != bound.scope.digest()?
        || decision.authority_digest != bound.authority_digest()?
    {
        return Err(Error::Denied);
    }
    Ok(Some(session))
}

impl Ledger {
    /// Read one principal's approved Session capabilities from the same current
    /// publication/fact cut used for turn admission. Discovery registers no task.
    pub fn provider_session_catalog(
        &mut self,
        session: &str,
        principal: &str,
    ) -> Result<ProviderSessionCatalog> {
        weaver_contracts::identifier(session)?;
        self.require_quiescent()?;
        let bound = read_scope(&self.connection, session)?;
        if principal != bound.scope.template.principal {
            return Err(Error::Denied);
        }
        let scope_commitment = bound.scope.digest()?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        if read_scope(&tx, session)? != bound {
            return Err(Error::Conflict("Session discovery source changed"));
        }
        let coordinates = current(&tx, &bound)?;
        let observed_facts = facts(&tx, &bound)?.commitment()?;
        let version = body_digest(&serde_json::to_string(&(
            "weaver.provider-session-catalog.v1",
            &scope_commitment,
            bound.authority_digest()?,
            coordinates,
            observed_facts,
        ))?);
        tx.commit().map_err(db)?;
        Ok(ProviderSessionCatalog {
            scope_commitment,
            version,
            models: bound.scope.template.models,
            profile: bound.scope.template.provider_profile.ok_or(Error::Denied)?,
        })
    }

    /// Source authentication is mandatory even for a trusted-host invocation.
    pub fn register_provider_session(&mut self, scope: &ProviderSessionScope) -> Result<()> {
        scope.validate()?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        let authority = crate::source_authority::current(&tx)?.ok_or(Error::Denied)?;
        if self.source.as_ref() != Some(&authority.identity) {
            return Err(Error::Denied);
        }
        let bound = BoundScope {
            authority,
            scope: scope.clone(),
        };
        current(&tx, &bound)?;
        let materialized: bool = persistence::one_current(&tx,
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE family=?1) OR EXISTS(SELECT 1 FROM provider_session_turns WHERE family=?1)",
            [scope.template.family.as_str()], |r| r.get(0),
        ).map_err(db)?;
        if materialized {
            return Err(Error::Conflict(
                "Session source overlaps a materialized original",
            ));
        }
        let record = serde_json::to_string(&bound)?;
        let old: Option<(String, String)> = persistence::maybe(
            &tx,
            "SELECT digest,record FROM provider_session_scopes WHERE session=?1",
            [scope.template.family.as_str()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(db)?;
        if old
            .as_ref()
            .is_some_and(|(digest, old)| old != &record || *digest != body_digest(&record))
        {
            return Err(Error::Conflict("Session source scope is immutable"));
        }
        persistence::exec(
            &tx,
            "INSERT INTO provider_session_scopes VALUES(?1,?2,?3) ON CONFLICT(session) DO NOTHING",
            [
                scope.template.family.as_str(),
                body_digest(&record).as_str(),
                record.as_str(),
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)
    }

    /// Observe source, publication and clear fact prefix without holding SQL
    /// across Scheme derivation. This object is not an admission permit.
    pub fn prepare_provider_turn(
        &mut self,
        request: ProviderSessionRequest,
    ) -> Result<ProviderSessionCut> {
        weaver_contracts::identifier(&request.session)?;
        self.require_quiescent()?;
        let bound = read_scope(&self.connection, &request.session)?;
        let submission_digest = bound
            .scope
            .submission_digest(&request.principal, &request.submission)?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        if read_scope(&tx, &request.session)? != bound {
            return Err(Error::Conflict(
                "Session source changed during request parsing",
            ));
        }
        let (revision, fence) = current(&tx, &bound)?;
        let facts = facts(&tx, &bound)?;
        let mut cut = ProviderSessionCut {
            bound,
            request,
            submission_digest,
            facts,
            revision,
            fence,
            retained: None,
        };
        cut.retained = retained_decision(&tx, &cut)?;
        tx.commit().map_err(db)?;
        Ok(cut)
    }

    /// Atomic immutable original, retry decision, turn count and parent linkage.
    /// Existing budget reservation/claim transactions still own actual exposure.
    pub fn register_provider_turn(
        &mut self,
        observed: &ProviderSessionCut,
        derived: &ProviderTurnDerivation,
    ) -> Result<ProviderTurnDerivation> {
        observed.bound.scope.admits(
            &observed.request.principal,
            &observed.request.submission,
            derived,
        )?;
        let prepared = prepare_decision(observed, derived)?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        require_cut(&tx, observed)?;
        let derived = decide(&tx, observed, prepared)?;
        crate::task_origins::default_binding(
            &tx,
            &derived.task,
            Some(&derived.domains),
            Some(&observed.bound.scope.publication),
        )?;
        crate::store::register_task_in(
            &tx,
            &derived.task,
            Some(&observed.bound.scope.publication),
            Some(&derived.domains),
        )?;
        tx.commit_provider().map_err(db)?;
        Ok(derived)
    }
}

fn require_cut(c: &Connection, observed: &ProviderSessionCut) -> Result<()> {
    let bound = read_scope(c, &observed.request.session)?;
    if bound != observed.bound
        || current(c, &bound)? != (observed.revision, observed.fence)
        || facts(c, &bound)? != observed.facts
    {
        return Err(Error::Conflict("Session deciding cut changed"));
    }
    Ok(())
}

fn decide(
    c: &Connection,
    observed: &ProviderSessionCut,
    prepared: PreparedDecision,
) -> Result<ProviderTurnDerivation> {
    if let Some(derived) = retained_decision(c, observed)? {
        return Ok(derived);
    }
    retain_decision(c, observed, prepared)
}

fn retained_decision(
    c: &Connection,
    observed: &ProviderSessionCut,
) -> Result<Option<ProviderTurnDerivation>> {
    let request = &observed.request;
    let old: Option<(String, String, String)> = persistence::maybe_current(c,
        "SELECT digest,record,derivation FROM provider_session_turns WHERE session=?1 AND operation_id=?2",
        [request.session.as_str(), request.submission.operation_id.as_str()], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    ).map_err(db)?;
    if let Some((old_digest, record, derivation)) = old {
        return recover(observed, old_digest, record, derivation).map(Some);
    }
    Ok(None)
}

fn recover(
    observed: &ProviderSessionCut,
    old_digest: String,
    record: String,
    derivation: String,
) -> Result<ProviderTurnDerivation> {
    let decision: Decision = weaver_contracts::decode(record.as_bytes())?;
    if body_digest(&record) != old_digest
        || decision.submission_digest != observed.submission_digest
        || decision.scope_digest != observed.bound.scope.digest()?
        || decision.authority_digest != observed.bound.authority_digest()?
        || decision.session != observed.request.session
        || decision.operation_id != observed.request.submission.operation_id
    {
        return Err(Error::Conflict("Session retry decision changed"));
    }
    let retained: RetainedDerivation = weaver_contracts::decode(derivation.as_bytes())?;
    let derived = retained.restore(&observed.request.submission)?;
    if decision.family != derived.task.family
        || decision.node != derived.plan.node
        || decision.task_digest != body_digest(&serde_json::to_string(&derived.task)?)
        || decision.plan_digest != derived.plan.digest()?
        || decision.domains_digest != body_digest(&serde_json::to_string(&derived.domains)?)
        || derived.plan.revision != observed.revision
        || derived.plan.fence != observed.fence
    {
        return Err(Error::Conflict("Session retry decision changed"));
    }
    observed.bound.scope.admits(
        &observed.request.principal,
        &observed.request.submission,
        &derived,
    )?;
    Ok(derived)
}

struct PreparedDecision {
    derived: ProviderTurnDerivation,
    binding: Decision,
    record: String,
    record_digest: String,
    retained: String,
}
fn prepare_decision(
    observed: &ProviderSessionCut,
    derived: &ProviderTurnDerivation,
) -> Result<PreparedDecision> {
    let mut derived = derived.clone();
    derived.plan.revision = observed.revision;
    derived.plan.fence = observed.fence;
    let decision = Decision {
        session: observed.request.session.clone(),
        operation_id: observed.request.submission.operation_id.clone(),
        scope_digest: observed.bound.scope.digest()?,
        authority_digest: observed.bound.authority_digest()?,
        submission_digest: observed.submission_digest.clone(),
        family: derived.task.family.clone(),
        node: derived.plan.node.clone(),
        task_digest: body_digest(&serde_json::to_string(&derived.task)?),
        plan_digest: derived.plan.digest()?,
        domains_digest: body_digest(&serde_json::to_string(&derived.domains)?),
    };
    let record = serde_json::to_string(&decision)?;
    let record_digest = body_digest(&record);
    let retained = serde_json::to_string(&RetainedDerivation::capture(&derived))?;
    Ok(PreparedDecision {
        derived,
        binding: decision,
        record,
        record_digest,
        retained,
    })
}

fn retain_decision(
    c: &Connection,
    observed: &ProviderSessionCut,
    prepared: PreparedDecision,
) -> Result<ProviderTurnDerivation> {
    let count: u64 = persistence::one_current(
        c,
        "SELECT COUNT(*) FROM provider_session_turns WHERE session=?1",
        [observed.request.session.as_str()],
        |r| integer(r, 0),
    )
    .map_err(db)?;
    if count >= observed.bound.scope.max_turns {
        return Err(Error::Conflict("Session turn limit exhausted"));
    }
    let retained: bool = persistence::one_current(c,
        "SELECT EXISTS(SELECT 1 FROM original_tasks WHERE family=?1) OR EXISTS(SELECT 1 FROM tasks WHERE family=?1)",
        [prepared.derived.task.family.as_str()], |r| r.get(0),
    ).map_err(db)?;
    if retained {
        return Err(Error::Conflict(
            "Session retry decision missing from retained original",
        ));
    }
    let PreparedDecision {
        derived,
        binding: decision,
        record,
        record_digest,
        retained,
    } = prepared;
    persistence::exec(
        c,
        "INSERT INTO provider_session_turns VALUES(?1,?2,?3,?4,?5,?6,?7)",
        [
            decision.session.as_str(),
            decision.operation_id.as_str(),
            derived.task.family.as_str(),
            derived.plan.node.as_str(),
            record_digest.as_str(),
            record.as_str(),
            retained.as_str(),
        ],
    )
    .map_err(db)?;
    Ok(derived)
}

#[cfg(test)]
#[path = "../tests/unit/provider_session.rs"]
mod tests;
