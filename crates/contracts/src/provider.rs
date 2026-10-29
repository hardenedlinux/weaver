//! Source-committed provider routes; observations never confer retry authority.
use crate::{Error, MAX_BODY_BYTES, MAX_CREDITS, Result, Task, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// One source-approved provider target and exact HTTPS destination.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderRoute {
    pub target: String,
    pub endpoint: String,
}
/// Immutable request, route ordering and reservation under an original task.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderPlan {
    pub family: String,
    pub node: String,
    pub profile: String,
    pub profile_commitment: String,
    pub model: String,
    pub body: String,
    pub routes: Vec<ProviderRoute>,
    pub ceiling: u64,
    pub revision: u64,
    pub fence: u64,
}
impl ProviderPlan {
    pub fn validate(&self) -> Result<()> {
        for id in [&self.family, &self.node, &self.profile, &self.model] {
            identifier(id)?;
        }
        if self.profile_commitment.len() != 64
            || !self
                .profile_commitment
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(Error::Invalid("provider profile commitment"));
        }
        if self.routes.is_empty()
            || self.routes.len() > 8
            || self.ceiling == 0
            || self.ceiling > MAX_CREDITS
            || self.revision > MAX_CREDITS
            || self.fence > MAX_CREDITS
            || self.body.len() > MAX_BODY_BYTES
        {
            return Err(Error::Invalid("provider plan bounds"));
        }
        let body: serde_json::Value = crate::decode(self.body.as_bytes())?;
        if body.get("model").and_then(|v| v.as_str()) != Some(&self.model)
            || body.get("stream") != Some(&serde_json::Value::Bool(true))
            || body.get("n").is_some_and(|v| v.as_u64() != Some(1))
            || body.get("tools").is_some()
            || body.get("tool_choice").is_some()
            || body.get("functions").is_some()
            || body.get("function_call").is_some()
        {
            return Err(Error::Invalid("text-only streaming profile required"));
        }
        // A source commitment is not a provider-specific precedence rule.
        // Never let a bounded preferred field hide a competing unbounded cap.
        let limit = match (body.get("max_completion_tokens"), body.get("max_tokens")) {
            (Some(value), None) | (None, Some(value)) => value.as_u64(),
            _ => None,
        };
        if limit.is_none_or(|n| n == 0 || n > 4096)
            || body
                .get("messages")
                .and_then(|v| v.as_array())
                .is_none_or(|m| m.is_empty() || m.len() > 64)
        {
            return Err(Error::Invalid("bounded provider request required"));
        }
        let mut targets = std::collections::BTreeSet::new();
        let mut endpoints = std::collections::BTreeSet::new();
        for r in &self.routes {
            identifier(&r.target)?;
            if !targets.insert(&r.target) || !endpoints.insert(&r.endpoint) {
                return Err(Error::Invalid("duplicate provider route"));
            }
        }
        Ok(())
    }
    /// Stable source commitment excludes observation generations, never routes or payload.
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.provider-plan.v2",
            &self.family,
            &self.node,
            &self.profile,
            &self.profile_commitment,
            &self.model,
            body_digest(&self.body),
            &self.routes,
            self.ceiling,
        ))?))
    }
    pub fn matches(&self, task: &Task) -> Result<bool> {
        Ok(self.binding(task)?.is_some())
    }
    pub fn binding(&self, task: &Task) -> Result<Option<crate::ProviderRequestFacts>> {
        if !(task.family == self.family
            && task.profile == self.profile
            && task.nodes.contains(&self.node)
            && task.models.contains(&self.model)
            && task.body_digests.get(&self.node) == Some(&body_digest(&self.body))
            && task.stream_contracts.get(&self.node) == Some(&self.digest()?)
            && task
                .node_cost_bounds
                .get(&self.node)
                .is_some_and(|cost| *cost <= self.ceiling)
            && self.ceiling <= task.budget
            && self.routes.iter().all(|r| {
                task.targets.contains(&r.target)
                    && task.endpoints.get(&r.target) == Some(&r.endpoint)
            }))
        {
            return Ok(None);
        }
        let Some(profile) = &task.provider_profile else {
            return Ok(None);
        };
        if profile.id != self.profile || profile.digest()? != self.profile_commitment {
            return Ok(None);
        }
        Ok(Some(profile.request_facts(&self.body)?))
    }
}
/// Closed response event kinds; tools never become executable capabilities.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderEventKind {
    Delta,
    Finish,
    Usage,
    Done,
}
impl ProviderEventKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Delta => "delta",
            Self::Finish => "finish",
            Self::Usage => "usage",
            Self::Done => "done",
        }
    }
}
/// Closed durable provider knowledge, separate from usage settlement.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderState {
    Queued,
    Unknown,
    Complete,
}
impl ProviderState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Unknown => "unknown",
            Self::Complete => "complete",
        }
    }
}
/// One bounded provider observation released under current authority.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProviderEvent {
    pub sequence: u64,
    pub kind: ProviderEventKind,
    pub text: String,
    pub tokens: u64,
}
/// Recoverable canonical operation outcome; completion does not refund its hold.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ProviderReceipt {
    pub family: String,
    pub node: String,
    pub digest: String,
    pub state: ProviderState,
    pub target: Option<String>,
    pub reserved: u64,
    pub held: u64,
    pub events: u64,
}
