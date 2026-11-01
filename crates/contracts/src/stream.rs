//! Finite source-owned stream manifest and immutable message proposals.
use crate::{Error, MAX_BODY_BYTES, MAX_CREDITS, Result, Task, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// One declared logical message; identity and cost cannot be invented by an adapter.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MessageRule {
    pub id: String,
    pub max_bytes: u64,
    pub cost_bound: u64,
}

/// Trusted publisher projection, bound to the original input and exact output destination.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamContract {
    pub family: String,
    pub node: String,
    pub profile: String,
    pub target: String,
    pub input_digest: String,
    pub destination: String,
    pub messages: Vec<MessageRule>,
}
impl StreamContract {
    /// Validate finite identity, size and source-owned cost bounds.
    pub fn validate(&self) -> Result<()> {
        for s in [&self.family, &self.node, &self.profile, &self.target] {
            identifier(s)?;
        }
        if self.messages.is_empty() || self.messages.len() > 64 || self.destination.len() > 512 {
            return Err(Error::Invalid("stream manifest bounds"));
        }
        validate_rules(&self.messages)?;
        Ok(())
    }
    /// Require the same source task, profile, node, target and original input commitment.
    pub fn matches(&self, task: &Task) -> bool {
        task.provider_profile.is_none()
            && self
                .digest()
                .is_ok_and(|d| task.stream_contracts.get(&self.node) == Some(&d))
            && self.family == task.family
            && self.profile == task.profile
            && task.nodes.contains(&self.node)
            && task.targets.contains(&self.target)
            && task.body_digests.get(&self.node) == Some(&self.input_digest)
    }
    /// Stable domain-separated manifest identity, independent of transport incarnation.
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.stream.v1",
            self,
        ))?))
    }
}
fn validate_rules(rules: &[MessageRule]) -> Result<()> {
    let mut total = 0u64;
    let mut ids = std::collections::BTreeSet::new();
    for rule in rules {
        identifier(&rule.id)?;
        if !ids.insert(&rule.id)
            || rule.max_bytes == 0
            || rule.max_bytes > MAX_BODY_BYTES as u64
            || rule.cost_bound == 0
            || rule.cost_bound > MAX_CREDITS
        {
            return Err(Error::Invalid("message rule"));
        }
        total = total
            .checked_add(rule.cost_bound)
            .ok_or(Error::Invalid("stream cost overflow"))?;
    }
    if total > MAX_CREDITS {
        return Err(Error::Invalid("stream cost overflow"));
    }
    Ok(())
}

/// Adapter data; revision and fence are observations that the deciding owner rechecks.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamMessage {
    pub family: String,
    pub node: String,
    pub message: String,
    pub contract_digest: String,
    pub payload: String,
    pub ceiling: u64,
    pub revision: u64,
    pub fence: u64,
}
impl StreamMessage {
    /// Reject oversized payloads, invalid identities and unrepresentable generations.
    pub fn validate(&self) -> Result<()> {
        for s in [&self.family, &self.node, &self.message] {
            identifier(s)?;
        }
        if self.payload.is_empty()
            || self.payload.len() > MAX_BODY_BYTES
            || self.ceiling == 0
            || self.ceiling > MAX_CREDITS
            || self.revision > MAX_CREDITS
            || self.fence > MAX_CREDITS
        {
            return Err(Error::Invalid("stream message bounds"));
        }
        Ok(())
    }
    /// Preserve logical content identity across reauthorization, new nonces and reconnects.
    pub fn digest(&self) -> Result<String> {
        self.binding()?.digest()
    }
    /// Hash payload once at admission; range checks use immutable metadata and bounded BLOB slices.
    pub fn binding(&self) -> Result<MessageBinding> {
        self.validate()?;
        Ok(MessageBinding {
            family: self.family.clone(),
            node: self.node.clone(),
            message: self.message.clone(),
            contract_digest: self.contract_digest.clone(),
            payload_digest: body_digest(&self.payload),
            payload_length: self.payload.len() as u64,
            ceiling: self.ceiling,
        })
    }
}

/// Small persistent commitment; Turso immutability binds its separately stored payload BLOB.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MessageBinding {
    pub family: String,
    pub node: String,
    pub message: String,
    pub contract_digest: String,
    pub payload_digest: String,
    pub payload_length: u64,
    pub ceiling: u64,
}
impl MessageBinding {
    /// Source, message, payload and reservation identity without rehashing the full body per range.
    pub fn digest(&self) -> Result<String> {
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.message.v2",
            &self.family,
            &self.node,
            &self.message,
            &self.contract_digest,
            &self.payload_digest,
            self.payload_length,
            self.ceiling,
        ))?))
    }
}

/// Durable knowledge about one message; only complete ranges advance the cursor.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MessageState {
    Queued,
    Active,
    Unknown,
    Complete,
}

/// Queryable message outcome, never an execution capability.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MessageReceipt {
    pub digest: String,
    pub state: MessageState,
    pub cursor: u64,
    pub reserved: u64,
}

/// Trusted local transport observation, not provider terminal/usage evidence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteObservation {
    Complete,
    Partial(u64),
    Unknown,
}
