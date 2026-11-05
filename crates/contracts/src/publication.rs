// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Stable source publication identities and historical decisions, never execution grants.
use crate::{Error, MAX_CREDITS, Result, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// Exact typed Policy proposal. A retry retains every field, including its original ID.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Publication {
    pub operation_id: String,
    pub expected_revision: Option<u64>,
    pub fence: u64,
    pub policy: String,
    pub schema: String,
}
impl Publication {
    pub fn validate(&self) -> Result<()> {
        identifier(&self.operation_id)?;
        if self.expected_revision.is_some_and(|r| r > MAX_CREDITS)
            || self.fence > MAX_CREDITS
            || self.policy.is_empty()
            || self.policy.len() > 65536
            || self.schema.is_empty()
            || self.schema.len() > 65536
        {
            return Err(Error::Invalid("publication bounds"));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.authority-publication.v1",
            &self.operation_id,
            self.expected_revision,
            self.fence,
            body_digest(&self.policy),
            body_digest(&self.schema),
        ))?))
    }
}

/// Immutable CAS decision; committed does not mean the revision remains current.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PublicationOutcome {
    Committed,
    Rejected,
}

/// Historical decision with the applied or conflict-observed head, possibly absent.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublicationReceipt {
    pub operation_id: String,
    pub digest: String,
    pub outcome: PublicationOutcome,
    pub revision: Option<u64>,
    pub fence: Option<u64>,
}
/// Source-ledger decision lookup; a key conveys no publication or execution authority.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublicationKey {
    pub operation_id: String,
    pub digest: String,
}
impl PublicationKey {
    pub fn validate(&self) -> Result<()> {
        identifier(&self.operation_id)?;
        if self.digest.len() != 64
            || !self
                .digest
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            return Err(Error::Invalid("publication digest"));
        }
        Ok(())
    }
}
impl PublicationReceipt {
    pub fn validate(&self) -> Result<()> {
        identifier(&self.operation_id)?;
        if self.digest.len() != 64
            || !self
                .digest
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            || self.revision.is_some() != self.fence.is_some()
            || self.revision.is_some_and(|r| r > MAX_CREDITS)
            || self.fence.is_some_and(|f| f > MAX_CREDITS)
            || (self.outcome == PublicationOutcome::Committed && self.revision.is_none())
        {
            return Err(Error::Invalid("publication receipt"));
        }
        Ok(())
    }
}
