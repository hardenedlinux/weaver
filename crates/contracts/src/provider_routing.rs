// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded declarative provider selection; no rule evaluator or execution permit.
use crate::{Error, ProviderPlan, Publication, Result, Task, identifier};
use serde::Deserialize;

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
/// Source selection policy for one original operation; conveys no send authority.
pub struct RoutingSelection {
    /// Original operation node to select.
    pub node: String,
    /// Tenant-admitted module identifiers.
    pub allowed_modules: Vec<String>,
    /// Capabilities required by this source profile.
    pub required: Vec<String>,
    /// Maximum admitted latency observation in milliseconds.
    pub max_latency_ms: u64,
    /// Maximum rounded procurement charge.
    pub max_procurement_cost: u64,
    /// Four integer token prices per million tokens.
    pub user_token_rates: [u64; 4],
    /// Bounded source offers; invalid request bindings are ineligible.
    pub candidates: Vec<RoutingCandidate>,
}
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
/// Concrete offer and conservative token facts; Rust validates its plan binding.
pub struct RoutingCandidate {
    /// Module identity supplied by the trusted source.
    pub module: String,
    /// Capabilities advertised by this admitted module.
    pub capabilities: Vec<String>,
    /// Positive observed latency in milliseconds.
    pub latency_ms: u64,
    /// Four integer procurement prices per million tokens.
    pub procurement_rates: [u64; 4],
    /// Conservative token bounds in the existing four metering categories.
    pub token_bounds: [u64; 4],
    /// Concrete immutable plan, independently checked by Rust.
    pub plan: ProviderPlan,
}

/// A source-owned one-operation selection declared before its first use.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderRoutingScope {
    pub task: Task,
    pub selection_schema: String,
    pub selection: RoutingSelection,
    pub publication: Publication,
}
impl ProviderRoutingScope {
    pub fn validate(&self) -> Result<()> {
        self.publication.validate()?;
        identifier(&self.selection_schema)?;
        identifier(&self.task.family)?;
        identifier(&self.selection.node)?;
        if self.task.nodes != [self.selection.node.clone()]
            || !self.task.body_digests.is_empty()
            || !self.task.stream_contracts.is_empty()
            || self.selection.candidates.is_empty()
            || self.selection.candidates.len() > 8
            || self.selection.allowed_modules.len() > 64
            || self.selection.required.len() > 64
            || serde_json::to_vec(self)?.len() > 8 * 1024 * 1024
        {
            return Err(Error::Invalid("provider routing scope bounds"));
        }
        Ok(())
    }
    /// Registration may fill only the selected original's commitment maps.
    pub fn admits(&self, task: &Task, plan: &ProviderPlan) -> Result<()> {
        self.validate()?;
        task.validate()?;
        plan.validate()?;
        let mut expected = self.task.clone();
        expected.body_digests.clone_from(&task.body_digests);
        expected.stream_contracts.clone_from(&task.stream_contracts);
        if *task != expected
            || plan.node != self.selection.node
            || !plan.matches(task)?
            || !self
                .selection
                .candidates
                .iter()
                .any(|candidate| candidate.plan == *plan)
        {
            return Err(Error::Denied);
        }
        Ok(())
    }
}

/// Published immutable original data or a source-declared deferred selection.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ProviderOperationScope {
    Fixed {
        task: Task,
        plan: ProviderPlan,
        publication: Publication,
    },
    Catalog {
        routing: ProviderRoutingScope,
    },
}
impl ProviderOperationScope {
    pub fn task(&self) -> &Task {
        match self {
            Self::Fixed { task, .. } => task,
            Self::Catalog { routing } => &routing.task,
        }
    }
    pub fn node(&self) -> &str {
        match self {
            Self::Fixed { plan, .. } => &plan.node,
            Self::Catalog { routing } => &routing.selection.node,
        }
    }
    pub fn publication(&self) -> &Publication {
        match self {
            Self::Fixed { publication, .. } => publication,
            Self::Catalog { routing } => &routing.publication,
        }
    }
    pub fn validate(&self) -> Result<()> {
        match self {
            Self::Catalog { routing } => routing.validate(),
            Self::Fixed {
                task,
                plan,
                publication,
            } => {
                publication.validate()?;
                task.validate()?;
                plan.validate()?;
                if !plan.matches(task)? {
                    return Err(Error::Denied);
                }
                Ok(())
            }
        }
    }
    pub fn admits(&self, task: &Task, plan: &ProviderPlan) -> Result<()> {
        self.validate()?;
        match self {
            Self::Catalog { routing } => routing.admits(task, plan),
            Self::Fixed {
                task: original,
                plan: chosen,
                ..
            } => {
                if task == original && plan == chosen {
                    Ok(())
                } else {
                    Err(Error::Denied)
                }
            }
        }
    }
}

/// Durable source provenance, not an operation caller's delegated source credential.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderOperationBinding {
    pub authority: crate::SourceAuthority,
    pub scope: ProviderOperationScope,
}
