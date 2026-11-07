// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Count actual UTF-8 data/key bytes without encoding an interop blob.
use crate::{SourceData, SourceSelection};
use weaver_contracts::{ProviderPlan, ProviderProfile, ProviderRoute, Publication, Task};
struct Bytes(usize);
impl Bytes {
    fn add(&mut self, text: &str) -> Option<()> {
        self.0 = self.0.checked_add(text.len())?;
        Some(())
    }
    fn strings(&mut self, values: &[String]) -> Option<()> {
        for value in values {
            self.add(value)?;
        }
        Some(())
    }
    fn texts(&mut self, values: &std::collections::BTreeMap<String, String>) -> Option<()> {
        for (key, value) in values {
            self.add(key)?;
            self.add(value)?;
        }
        Some(())
    }
}
pub(super) fn text_bytes(data: &SourceData) -> Option<usize> {
    let SourceData {
        governance,
        tasks,
        plans,
        publication,
    } = data;
    let SourceSelection {
        schema,
        family,
        open_nodes,
        workflow_edges,
        workflow_selectors,
    } = governance;
    let mut bytes = Bytes(0);
    bytes.add(schema)?;
    bytes.add(family)?;
    bytes.strings(open_nodes)?;
    for (child, parent) in workflow_edges {
        bytes.add(child)?;
        bytes.add(parent)?;
    }
    for selector in workflow_selectors {
        bytes.strings(selector)?;
    }
    for task in tasks {
        let Task {
            family,
            principal,
            profile,
            provider_profile,
            nodes,
            targets,
            endpoints,
            body_digests,
            node_cost_bounds,
            stream_contracts,
            models,
            budget: _,
        } = task;
        for value in [family, principal, profile] {
            bytes.add(value)?;
        }
        for values in [nodes, targets, models] {
            bytes.strings(values)?;
        }
        for values in [endpoints, body_digests, stream_contracts] {
            bytes.texts(values)?;
        }
        for key in node_cost_bounds.keys() {
            bytes.add(key)?;
        }
        if let Some(profile) = provider_profile {
            let ProviderProfile {
                id,
                protocol,
                max_output_tokens: _,
                max_messages: _,
                max_body_bytes: _,
            } = profile;
            bytes.add(id)?;
            bytes.add(protocol)?;
        }
    }
    for plan in plans {
        let ProviderPlan {
            family,
            node,
            profile,
            profile_commitment,
            model,
            body,
            routes,
            ceiling: _,
            revision: _,
            fence: _,
        } = plan;
        for value in [family, node, profile, profile_commitment, model, body] {
            bytes.add(value)?;
        }
        for route in routes {
            let ProviderRoute { target, endpoint } = route;
            bytes.add(target)?;
            bytes.add(endpoint)?;
        }
    }
    let Publication {
        operation_id,
        expected_revision: _,
        fence: _,
        policy,
        schema,
    } = publication;
    for value in [operation_id, policy, schema] {
        bytes.add(value)?;
    }
    Some(bytes.0)
}
