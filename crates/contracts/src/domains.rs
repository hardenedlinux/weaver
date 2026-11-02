//! Source-owned identity and monotone domain-union commands, never send grants.
use crate::{Error, MAX_CREDITS, Result, identifier};
use serde::{Deserialize, Serialize};

/// Immutable source assignment of one original task to shared constraint domains.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainBinding {
    pub origin: String,
    pub budget: String,
    pub history: String,
    pub budget_limit: u64,
}
impl DomainBinding {
    pub fn validate(&self) -> Result<()> {
        for id in [&self.origin, &self.budget, &self.history] {
            identifier(id)?;
        }
        if self.budget_limit == 0 || self.budget_limit > MAX_CREDITS {
            return Err(Error::Invalid("domain budget limit"));
        }
        Ok(())
    }
}
/// Observable domain coordinates; only a private executor handle carries authority.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainStamp {
    pub origin: String,
    pub budget_root: String,
    pub history_root: String,
    pub budget_epoch: u64,
    pub history_epoch: u64,
}
/// Current registry projection, never a reusable permission to perform an effect.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainView {
    pub family: String,
    pub canonical_family: String,
    pub stamp: DomainStamp,
    pub budget_limit: u64,
    pub held: u64,
    pub history_count: u64,
}
/// Exact-parent whole-domain union proposal; it cannot detach an original family.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainMigration {
    pub operation_id: String,
    pub budget_from: String,
    pub budget_to: String,
    pub history_from: String,
    pub history_to: String,
    pub budget_from_epoch: u64,
    pub budget_to_epoch: u64,
    pub history_from_epoch: u64,
    pub history_to_epoch: u64,
}
impl DomainMigration {
    pub fn validate(&self) -> Result<()> {
        for id in [
            &self.operation_id,
            &self.budget_from,
            &self.budget_to,
            &self.history_from,
            &self.history_to,
        ] {
            identifier(id)?;
        }
        Ok(())
    }
}
/// Durable original migration outcome, recovered by operation ID and command digest.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DomainMigrationReceipt {
    pub operation_id: String,
    pub digest: String,
    pub committed: bool,
    pub budget_root: String,
    pub history_root: String,
    pub budget_epoch: u64,
    pub history_epoch: u64,
}
