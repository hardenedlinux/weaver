// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source-bound task, proposal and durable outcome records.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Commit the exact UTF-8 request bytes before provider dispatch.
pub fn body_digest(body: &str) -> String {
    hex::encode(Sha256::digest(body.as_bytes()))
}

/// Maximum accepted UTF-8 request body size.
pub const MAX_BODY_BYTES: usize = 1_048_576;
/// Maximum representable deciding-store budget.
pub const MAX_CREDITS: u64 = i64::MAX as u64;

/// Typed boundary failures without prompt or credential disclosure.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("invalid contract: {0}")]
    Invalid(&'static str),
    #[error("state conflict: {0}")]
    Conflict(&'static str),
    #[error("authorization denied")]
    Denied,
    #[error("storage: {0}")]
    Storage(String),
    #[error("policy: {0}")]
    Policy(String),
    #[error("codec: {0}")]
    Codec(#[from] serde_json::Error),
}
/// Result type for fallible boundary operations.
pub type Result<T> = std::result::Result<T, Error>;

/// Validate the bounded canonical identifier grammar.
pub fn identifier(s: &str) -> Result<()> {
    if s.is_empty()
        || s.len() > 128
        || !s
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._:-".contains(&c))
    {
        return Err(Error::Invalid("identifier"));
    }
    Ok(())
}

/// Untrusted adapter proposal, checked against the deciding original task.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Proposal {
    pub family: String,
    pub node: String,
    pub profile: String,
    pub target: String,
    pub endpoint: String,
    pub model: String,
    pub body: String,
    pub ceiling: u64,
    pub revision: u64,
    pub fence: u64,
}
impl Proposal {
    /// Reject malformed contracts before admission.
    pub fn validate(&self) -> Result<()> {
        for value in [
            &self.family,
            &self.node,
            &self.profile,
            &self.target,
            &self.model,
        ] {
            identifier(value)?;
        }
        if self.body.len() > MAX_BODY_BYTES || self.ceiling == 0 || self.ceiling > MAX_CREDITS {
            return Err(Error::Invalid("body or ceiling"));
        }
        if self.revision > MAX_CREDITS || self.fence > MAX_CREDITS {
            return Err(Error::Invalid("generation"));
        }
        let body: serde_json::Value = crate::decode(self.body.as_bytes())?;
        if body.get("model").and_then(|m| m.as_str()) != Some(&self.model) {
            return Err(Error::Invalid("wire model differs from selected model"));
        }
        if body.get("stream").is_some_and(|v| v != false) {
            return Err(Error::Invalid("streaming requires a range broker"));
        }
        if body.get("tools").is_some() || body.get("tool_choice").is_some() {
            return Err(Error::Invalid("tool execution profile not admitted"));
        }
        Ok(())
    }
    /// Domain separated ordered tuple, independent of object map order.
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        let bytes = serde_json::to_vec(&(
            "weaver.proposal.v1",
            &self.family,
            &self.node,
            &self.profile,
            &self.target,
            &self.endpoint,
            &self.model,
            &self.body,
            self.ceiling,
            self.revision,
            self.fence,
        ))?;
        Ok(hex::encode(Sha256::digest(bytes)))
    }
}

/// Authenticated publisher input, never an adapter-supplied registration.
/// Immutable original task supplied only by an authenticated publisher.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Task {
    pub family: String,
    pub principal: String,
    pub profile: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_profile: Option<crate::ProviderProfile>,
    pub nodes: Vec<String>,
    pub targets: Vec<String>,
    pub endpoints: std::collections::BTreeMap<String, String>,
    pub body_digests: std::collections::BTreeMap<String, String>,
    pub node_cost_bounds: std::collections::BTreeMap<String, u64>,
    pub stream_contracts: std::collections::BTreeMap<String, String>,
    pub models: Vec<String>,
    pub budget: u64,
}
impl Task {
    /// Reject malformed contracts before admission.
    pub fn validate(&self) -> Result<()> {
        for s in [&self.family, &self.principal, &self.profile] {
            identifier(s)?;
        }
        if let Some(profile) = &self.provider_profile {
            profile.validate()?;
            if profile.id != self.profile {
                return Err(Error::Invalid("task profile identity"));
            }
        }
        for set in [&self.nodes, &self.targets, &self.models] {
            validate_set(set)?;
        }
        if self.budget == 0 || self.budget > MAX_CREDITS {
            return Err(Error::Invalid("budget"));
        }
        if self.endpoints.len() != self.targets.len()
            || self.targets.iter().any(|t| !self.endpoints.contains_key(t))
        {
            return Err(Error::Invalid("target endpoint bindings"));
        }
        if self.body_digests.len() != self.nodes.len()
            || self.nodes.iter().any(|n| {
                self.body_digests.get(n).is_none_or(|d| {
                    d.len() != 64
                        || !d
                            .bytes()
                            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
                })
            })
        {
            return Err(Error::Invalid("original node body commitment"));
        }
        if self.node_cost_bounds.len() != self.nodes.len()
            || self.nodes.iter().any(|n| {
                self.node_cost_bounds
                    .get(n)
                    .is_none_or(|cost| *cost == 0 || *cost > self.budget)
            })
        {
            return Err(Error::Invalid("original node cost bound"));
        }
        if self.stream_contracts.iter().any(|(node, digest)| {
            !self.nodes.contains(node)
                || digest.len() != 64
                || !digest
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        }) {
            return Err(Error::Invalid("original stream commitment"));
        }
        Ok(())
    }
    /// Require the original task profile, node, target, model and body commitments.
    pub fn admits(&self, p: &Proposal) -> bool {
        self.provider_profile.is_none()
            && self.family == p.family
            && self.profile == p.profile
            && self.nodes.contains(&p.node)
            && self.targets.contains(&p.target)
            && self.models.contains(&p.model)
            && self.endpoints.get(&p.target) == Some(&p.endpoint)
            && self.body_digests.get(&p.node) == Some(&body_digest(&p.body))
            && self
                .node_cost_bounds
                .get(&p.node)
                .is_some_and(|cost| *cost <= p.ceiling)
    }
}

/// Durable execution knowledge; unknown outcomes retain their holds.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Queued,
    Unknown,
    ResponseReceived,
}

/// Recoverable observation bound to the canonical logical operation.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub family: String,
    pub node: String,
    pub digest: String,
    pub outcome: Outcome,
    pub reserved: u64,
}

fn validate_set(set: &[String]) -> Result<()> {
    if set.is_empty() || set.len() > 256 {
        return Err(Error::Invalid("empty or oversized task set"));
    }
    for (i, value) in set.iter().enumerate() {
        identifier(value)?;
        if set[..i].contains(value) {
            return Err(Error::Invalid("duplicate task member"));
        }
    }
    Ok(())
}
