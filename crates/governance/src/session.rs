// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Compact advisory turns for the existing Scheme owner; no prompt or permit.
use crate::SourceError;
use serde::{Deserialize, Serialize};
use weaver_contracts::ProviderSessionScope;

/// Authenticated ingress facts, independently checked against exact bytes by Rust.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionTurnFacts {
    pub principal: String,
    pub model: String,
    pub output_token_limit: u64,
    pub message_count: u64,
    pub body_bytes: u64,
}

/// Inert source data and compact facts, evaluated outside the deciding transaction.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct SessionTurnInput {
    pub scope: ProviderSessionScope,
    pub facts: SessionTurnFacts,
}

/// Ordered source-route indices, bound to the exact source scope; not a grant.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionTurnSelection {
    pub scope_commitment: String,
    pub route_indices: Vec<usize>,
}

impl SessionTurnInput {
    pub fn validate(&self) -> Result<(), SourceError> {
        self.scope.validate().map_err(|_| SourceError::Contract)?;
        let profile = self
            .scope
            .template
            .provider_profile
            .as_ref()
            .ok_or(SourceError::Contract)?;
        if self.facts.principal != self.scope.template.principal
            || !self.scope.template.models.contains(&self.facts.model)
            || !(1..=profile.max_output_tokens).contains(&self.facts.output_token_limit)
            || !(1..=profile.max_messages).contains(&self.facts.message_count)
            || !(1..=profile.max_body_bytes).contains(&self.facts.body_bytes)
        {
            return Err(SourceError::Binding);
        }
        Ok(())
    }
}
impl SessionTurnSelection {
    /// Reject foreign, duplicate, oversized or out-of-scope advisory results.
    pub fn validate_for(&self, input: &SessionTurnInput) -> Result<(), SourceError> {
        input.validate()?;
        if self.scope_commitment != input.scope.digest().map_err(|_| SourceError::Contract)?
            || self.route_indices.is_empty()
            || self.route_indices.len() > 8
        {
            return Err(SourceError::Binding);
        }
        let mut seen = std::collections::BTreeSet::new();
        for index in &self.route_indices {
            if *index >= input.scope.template.targets.len() || !seen.insert(index) {
                return Err(SourceError::Binding);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
#[path = "../tests/unit/session.rs"]
mod tests;
