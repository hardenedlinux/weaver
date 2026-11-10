// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Trusted startup configuration; Scheme selects, Rust seals the resulting original.
use crate::SourceData;
use serde::Deserialize;

#[derive(Clone, serde::Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
/// Deployment-owned source and bounded selections, composed before original sealing.
pub struct SourceComposition {
    /// Unmaterialized source with no preexisting body or stream commitments.
    pub source: SourceData,
    /// At most 64 selections, each with at most eight candidates.
    pub routing: Vec<RoutingSelection>,
}
pub use weaver_contracts::{RoutingCandidate, RoutingSelection};

impl SourceComposition {
    /// Independently preserve the supplied original scope before sealing a result.
    /// Scheme chooses listed plans and fills commitments; it cannot rewrite the
    /// principal, profile, budget, endpoints, publication or declared topology.
    /// This checks scope preservation, not a second ranking implementation.
    pub fn validate_selected(
        &self,
        selected: &crate::OwnedSource,
    ) -> Result<(), crate::SourceError> {
        self.validate_inventory(selected)?;
        self.validate_scope(selected)?;
        self.validate_plan_membership(selected)
    }
    fn validate_inventory(&self, selected: &crate::OwnedSource) -> Result<(), crate::SourceError> {
        use crate::SourceError;
        if self.source.tasks.len() != 1
            || !self.source.plans.is_empty()
            || !self.source.tasks[0].body_digests.is_empty()
            || !self.source.tasks[0].stream_contracts.is_empty()
            || self.routing.len() != selected.plans().len()
        {
            return Err(SourceError::Binding);
        }
        Ok(())
    }
    fn validate_scope(&self, selected: &crate::OwnedSource) -> Result<(), crate::SourceError> {
        use crate::SourceError;
        let actual = selected.data();
        let original = &self.source;
        let mut expected_task = original.tasks[0].clone();
        expected_task
            .body_digests
            .clone_from(&selected.task().body_digests);
        expected_task
            .stream_contracts
            .clone_from(&selected.task().stream_contracts);
        if selected.task() != &expected_task
            || actual.publication != original.publication
            || actual.governance.schema != original.governance.schema
            || actual.governance.family != original.governance.family
            || actual.governance.open_nodes != original.governance.open_nodes
            || (!original.governance.workflow_edges.is_empty()
                && actual.governance.workflow_edges != original.governance.workflow_edges)
            || (!original.governance.workflow_selectors.is_empty()
                && actual.governance.workflow_selectors != original.governance.workflow_selectors)
        {
            return Err(SourceError::Binding);
        }
        Ok(())
    }
    fn validate_plan_membership(
        &self,
        selected: &crate::OwnedSource,
    ) -> Result<(), crate::SourceError> {
        use crate::SourceError;
        let mut nodes = std::collections::BTreeSet::new();
        let mut admitted = std::collections::BTreeMap::new();
        for row in &self.routing {
            if !nodes.insert(&row.node) || row.candidates.is_empty() || row.candidates.len() > 8 {
                return Err(SourceError::Binding);
            }
            for candidate in &row.candidates {
                if let Ok(digest) = candidate.plan.digest() {
                    admitted.insert(
                        (
                            row.node.as_str(),
                            digest,
                            candidate.plan.revision,
                            candidate.plan.fence,
                        ),
                        &candidate.plan,
                    );
                }
            }
        }
        for plan in selected.plans() {
            let digest = selected
                .task()
                .stream_contracts
                .get(&plan.node)
                .ok_or(SourceError::Binding)?;
            if admitted
                .get(&(
                    plan.node.as_str(),
                    digest.clone(),
                    plan.revision,
                    plan.fence,
                ))
                .is_none_or(|original| *original != plan)
            {
                return Err(SourceError::Binding);
            }
        }
        Ok(())
    }
}
