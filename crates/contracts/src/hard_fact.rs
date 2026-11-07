// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Durable fact-feed inputs and the sealed topology of a governed Session.

use crate::{Error, MAX_CREDITS, Result, SourceAuthority, body_digest, identifier};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Wire schema for an ordered Session path.
pub const SESSION_WORKFLOW_SCHEMA: &str = "weaver.session-workflow.v1";

/// Wire schema for a Session with concurrent branches and joins.
pub const SESSION_DAG_SCHEMA: &str = "weaver.session-dag.v1";
/// Wire schema for a Session with nested conditional gates.
pub const SESSION_NESTED_SCHEMA: &str = "weaver.session-nested.v1";
/// Wire schema for a Session with one two-arm selector.
pub const SESSION_CHOICE_SCHEMA: &str = "weaver.session-choice.v1";
/// Maximum size of a selector's completely released structured result.
pub const MAX_WORKFLOW_RESULT_BYTES: usize = 512;

/// A selector's typed route to one of its admitted arms.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WorkflowRoute {
    Left,
    Right,
}

impl WorkflowRoute {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Right => "right",
        }
    }

    pub fn arm(self, nodes: &[String; 4]) -> &str {
        match self {
            Self::Left => &nodes[1],
            Self::Right => &nodes[2],
        }
    }
}

/// Trusted deployment admission for one ledger-local, ordered availability feed.
/// Each edge is (dependent, dependency) within the independently admitted task.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FactFeed {
    pub domain: String,
    pub authority: SourceAuthority,
    pub family: String,
    pub root: String,
    pub dependencies: Vec<(String, String)>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workflow: Option<ProviderWorkflow>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub workflow_path: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub workflow_dag: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub workflow_choice: bool,
    /// Each selector names the entry of its left and right arms.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub workflow_selectors: Vec<[String; 3]>,
}

/// One explicitly admitted outgoing edge of a compiled Governor task.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderWorkflow {
    pub predecessor: String,
    pub successor: String,
}

impl FactFeed {
    pub fn session_schema(&self) -> &'static str {
        if !self.workflow_selectors.is_empty() {
            SESSION_NESTED_SCHEMA
        } else if self.workflow_choice {
            SESSION_CHOICE_SCHEMA
        } else if self.workflow_dag {
            SESSION_DAG_SCHEMA
        } else {
            SESSION_WORKFLOW_SCHEMA
        }
    }

    pub fn choice_nodes(&self) -> Option<&[String; 4]> {
        if self.workflow_choice {
            self.workflow_path.as_slice().try_into().ok()
        } else {
            None
        }
    }

    pub fn workflow_predecessors(&self, node: &str) -> Vec<&str> {
        if self.workflow_dag {
            return self
                .dependencies
                .iter()
                .filter(|(child, _)| child == node)
                .map(|(_, parent)| parent.as_str())
                .collect();
        }
        if let Some(edge) = &self.workflow {
            return (edge.successor == node)
                .then_some(edge.predecessor.as_str())
                .into_iter()
                .collect();
        }
        self.workflow_path
            .windows(2)
            .find(|pair| pair[1] == node)
            .map(|pair| pair[0].as_str())
            .into_iter()
            .collect()
    }

    pub fn validate(&self) -> Result<()> {
        identifier(&self.domain)?;
        identifier(&self.family)?;
        identifier(&self.root)?;
        self.authority.identity.validate()?;
        if self.authority.epoch > MAX_CREDITS || self.dependencies.len() > 64 {
            return Err(Error::Invalid("fact feed bounds"));
        }
        for (dependent, dependency) in &self.dependencies {
            identifier(dependent)?;
            identifier(dependency)?;
        }
        self.validate_workflow()
    }

    fn validate_workflow(&self) -> Result<()> {
        if let Some(workflow) = &self.workflow {
            identifier(&workflow.predecessor)?;
            identifier(&workflow.successor)?;
            if workflow.predecessor == workflow.successor {
                return Err(Error::Invalid("provider workflow edge"));
            }
        }
        if !self.workflow_path.is_empty() {
            if self.workflow.is_some()
                || !(2..=64).contains(&self.workflow_path.len())
                || self.workflow_path[0] != self.root
            {
                return Err(Error::Invalid("provider workflow path"));
            }
            let mut seen = BTreeSet::new();
            for node in &self.workflow_path {
                identifier(node)?;
                if !seen.insert(node) {
                    return Err(Error::Invalid("provider workflow repeated node"));
                }
            }
            if self.workflow_dag {
                validate_session_dag(&self.workflow_path, &self.dependencies)?;
            } else if self.workflow_path.windows(2).any(|pair| {
                !self
                    .dependencies
                    .iter()
                    .any(|(dependent, dependency)| dependent == &pair[1] && dependency == &pair[0])
            }) {
                return Err(Error::Invalid("provider workflow availability dependency"));
            }
        }
        if !self.workflow_selectors.is_empty() {
            if !self.workflow_dag || self.workflow_choice {
                return Err(Error::Invalid("nested Session profile"));
            }
            validate_session_selectors(
                &self.workflow_path,
                &self.dependencies,
                &self.workflow_selectors,
            )?;
        }
        if self.workflow_choice {
            if !self.workflow_dag {
                return Err(Error::Invalid("conditional Session requires DAG"));
            }
            validate_session_choice(&self.workflow_path, &self.dependencies)?;
        }
        if self.workflow_dag && self.workflow_path.is_empty() {
            return Err(Error::Invalid("Session DAG path missing"));
        }
        Ok(())
    }
}

/// Each gate is independently bound to an actual single-parent entry.
pub fn validate_session_selectors(
    nodes: &[String],
    edges: &[(String, String)],
    selectors: &[[String; 3]],
) -> Result<()> {
    validate_session_dag(nodes, edges)?;
    if selectors.is_empty() || selectors.len() > 31 {
        return Err(Error::Invalid("nested Session selector bound"));
    }
    if selectors.windows(2).any(|pair| pair[0][0] >= pair[1][0]) {
        return Err(Error::Invalid("nested Session selector order"));
    }
    let mut parents = BTreeMap::new();
    for (child, parent) in edges {
        parents
            .entry(child)
            .and_modify(|previous| *previous = None)
            .or_insert(Some(parent));
    }
    let mut entries = BTreeSet::new();
    for (entry, selector) in selectors
        .iter()
        .flat_map(|[selector, left, right]| [(left, selector), (right, selector)])
    {
        if !entries.insert(entry) || parents.get(entry) != Some(&Some(selector)) {
            return Err(Error::Invalid("nested Session gated entry"));
        }
    }
    Ok(())
}

/// A sealed choice has one selector, two ordered arms, and one join.
pub fn validate_session_choice(nodes: &[String], edges: &[(String, String)]) -> Result<()> {
    validate_session_dag(nodes, edges)?;
    let [root, left, right, join] = nodes else {
        return Err(Error::Invalid("conditional Session nodes"));
    };
    if edges.len() != 4
        || [(left, root), (right, root), (join, left), (join, right)]
            .iter()
            .any(|(child, parent)| !edges.iter().any(|(c, p)| c == *child && p == *parent))
    {
        return Err(Error::Invalid("conditional Session edges"));
    }
    Ok(())
}

/// Nodes are in topological order. Every node after the root has an incoming
/// edge, so the sealed graph has one root and every node is reachable from it.
pub fn validate_session_dag(nodes: &[String], edges: &[(String, String)]) -> Result<()> {
    if !(2..=64).contains(&nodes.len()) || edges.len() > 64 {
        return Err(Error::Invalid("Session DAG bounds"));
    }
    let order: BTreeMap<_, _> = nodes
        .iter()
        .enumerate()
        .map(|(index, node)| (node, index))
        .collect();
    if order.len() != nodes.len() {
        return Err(Error::Invalid("Session DAG repeated node"));
    }
    let mut seen = BTreeSet::new();
    let mut previous = None;
    for edge @ (child, parent) in edges {
        let child_index = order.get(child);
        let parent_index = order.get(parent);
        if !matches!((child_index, parent_index), (Some(c), Some(p)) if p < c)
            || previous.is_some_and(|last| last >= edge)
        {
            return Err(Error::Invalid("Session DAG edges"));
        }
        previous = Some(edge);
        seen.insert(child);
    }
    if nodes.iter().skip(1).any(|node| !seen.contains(node)) {
        return Err(Error::Invalid("Session DAG disconnected node"));
    }
    Ok(())
}

/// One authenticated proposal to change availability at a specific source cut.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FactIntent {
    pub operation_id: String,
    pub domain: String,
    pub source_epoch: u64,
    pub revision: u64,
    pub previous_snapshot: String,
    pub expected_floor: u64,
    pub available: bool,
}

impl FactIntent {
    pub fn snapshot(&self) -> Result<String> {
        identifier(&self.operation_id)?;
        identifier(&self.domain)?;
        if self.source_epoch > MAX_CREDITS
            || self.revision == 0
            || self.revision > MAX_CREDITS
            || self.expected_floor >= MAX_CREDITS
            || self.previous_snapshot.len() != 64
            || !self
                .previous_snapshot
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(Error::Invalid("hard fact intent bounds"));
        }
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.hard-fact.v1",
            self,
        ))?))
    }
}

/// The durable intent identity and ordered prefix that fence final use.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FactBarrier {
    pub operation_id: String,
    pub source_epoch: u64,
    pub revision: u64,
    pub snapshot: String,
    pub floor: u64,
    pub pending_prefix: String,
}

/// The committed availability projection and the remaining pending prefix.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FactResolution {
    pub barrier: FactBarrier,
    pub affected: Vec<String>,
    pub floor: u64,
    pub previous_pending_prefix: String,
    pub remaining_pending_prefix: Option<String>,
}

/// Detached from the persisted barrier; no caller-supplied graph or projection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FactWork {
    pub barrier: FactBarrier,
    pub expected_floor: u64,
    pub pending_prefix: String,
    pub root: String,
    pub dependencies: Vec<(String, String)>,
    pub available: bool,
}
