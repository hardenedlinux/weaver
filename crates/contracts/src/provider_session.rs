// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source-declared conversational bounds, never an admission or execution grant.
use crate::{
    DomainBinding, Error, ProviderPlan, ProviderRequestFacts, PublicationKey, Result, Task,
};
use serde::{Deserialize, Serialize};

/// Immutable source scope for changing turns under shared budget/history domains.
/// The template contains one declared node with no request commitments. Scheme
/// selects each concrete plan; Rust checks that only the permitted fields changed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderSessionScope {
    pub template: Task,
    pub domains: DomainBinding,
    pub publication: PublicationKey,
    pub max_turns: u64,
}

/// Untrusted bytes and retry key. Authentication supplies the principal separately.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderTurnSubmission {
    pub operation_id: String,
    pub body: String,
}

/// Concrete Scheme output. Its fields carry data, never a reusable authority cut.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderTurnDerivation {
    pub task: Task,
    pub plan: ProviderPlan,
    pub domains: DomainBinding,
}

impl std::fmt::Debug for ProviderTurnDerivation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderTurnDerivation")
            .field("body_bytes", &self.plan.body.len())
            .finish_non_exhaustive()
    }
}

impl std::fmt::Debug for ProviderTurnSubmission {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderTurnSubmission")
            .field("body_bytes", &self.body.len())
            .finish_non_exhaustive()
    }
}

impl ProviderSessionScope {
    pub fn validate(&self) -> Result<()> {
        self.template.validate_provider_template()?;
        self.domains.validate()?;
        self.publication.validate()?;
        if self.template.nodes.len() != 1
            || !self.template.body_digests.is_empty()
            || !self.template.stream_contracts.is_empty()
            || self.template.provider_profile.is_none()
            || self.domains.origin != self.template.family
            || self.domains.budget_limit != self.template.budget
            || !(1..=64).contains(&self.max_turns)
            || serde_json::to_vec(self)?.len() > 262_144
        {
            return Err(Error::Invalid("provider session scope"));
        }
        Ok(())
    }

    /// Covers source limits, routing bounds, shared domains and publication.
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(crate::body_digest(&serde_json::to_string(&(
            "weaver.provider-session-scope.v1",
            self,
        ))?))
    }

    /// Parse facts only after authenticating the caller against this source scope.
    pub fn request_facts(
        &self,
        principal: &str,
        submission: &ProviderTurnSubmission,
    ) -> Result<ProviderRequestFacts> {
        self.validate()?;
        crate::identifier(&submission.operation_id)?;
        if principal != self.template.principal {
            return Err(Error::Denied);
        }
        let profile = self
            .template
            .provider_profile
            .as_ref()
            .ok_or(Error::Denied)?;
        let facts = profile.request_facts(&submission.body)?;
        if !self.template.models.contains(&facts.model) {
            return Err(Error::Denied);
        }
        Ok(facts)
    }

    /// Deterministic source-owned family. Changing retry bytes keeps this same
    /// key so the ledger must reject a changed digest, rather than allocate anew.
    pub fn turn_family(&self, submission: &ProviderTurnSubmission) -> Result<String> {
        crate::identifier(&submission.operation_id)?;
        Ok(format!(
            "turn:{}",
            crate::body_digest(&serde_json::to_string(&(
                "weaver.provider-session-turn.v1",
                self.digest()?,
                &submission.operation_id,
            ))?)
        ))
    }

    /// A command commitment, not an idempotency lookup or admission decision.
    pub fn submission_digest(
        &self,
        principal: &str,
        submission: &ProviderTurnSubmission,
    ) -> Result<String> {
        self.request_facts(principal, submission)?;
        Ok(crate::body_digest(&serde_json::to_string(&(
            "weaver.provider-session-submission.v1",
            self.digest()?,
            principal,
            &submission.operation_id,
            crate::body_digest(&submission.body),
        ))?))
    }

    /// Independently check a Scheme-derived turn. This pure check deliberately
    /// does not assert current source/facts, quota, replay state or a send permit.
    /// Those must rejoin the same ledger transaction before registering the turn.
    pub fn admits(
        &self,
        principal: &str,
        submission: &ProviderTurnSubmission,
        derived: &ProviderTurnDerivation,
    ) -> Result<()> {
        let facts = self.request_facts(principal, submission)?;
        derived.task.validate()?;
        derived.plan.validate()?;
        derived.domains.validate()?;
        self.require_derivation(submission, derived, facts)
    }

    fn require_derivation(
        &self,
        submission: &ProviderTurnSubmission,
        derived: &ProviderTurnDerivation,
        facts: ProviderRequestFacts,
    ) -> Result<()> {
        let ProviderTurnDerivation {
            task,
            plan,
            domains,
        } = derived;
        let family = self.turn_family(submission)?;
        let node = &self.template.nodes[0];
        let mut expected = self.template.clone();
        expected.family.clone_from(&family);
        expected
            .body_digests
            .insert(node.clone(), crate::body_digest(&submission.body));
        expected
            .stream_contracts
            .insert(node.clone(), plan.digest()?);
        let mut expected_domains = self.domains.clone();
        expected_domains.origin = family;
        if *task != expected
            || *domains != expected_domains
            || plan.node != *node
            || plan.body != submission.body
            || plan.model != facts.model
            || self.template.node_cost_bounds.get(node) != Some(&plan.ceiling)
            || !plan.matches(task)?
        {
            return Err(Error::Denied);
        }
        Ok(())
    }
}
