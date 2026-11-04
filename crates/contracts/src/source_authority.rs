// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authenticated source key continuity. No Kubernetes label or request actor is authority.
use crate::{Error, MAX_CREDITS, Result, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// Digests of actual mTLS leaf, its SPKI and the authenticated role credential.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceIdentity {
    pub certificate_sha256: String,
    pub public_key_sha256: String,
    pub credential_sha256: String,
}
impl SourceIdentity {
    pub fn validate(&self) -> Result<()> {
        for digest in [
            &self.certificate_sha256,
            &self.public_key_sha256,
            &self.credential_sha256,
        ] {
            if digest.len() != 64
                || digest.bytes().all(|b| b == b'0')
                || !digest
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err(Error::Invalid("source identity digest"));
            }
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.source-identity.v1",
            self,
        ))?))
    }
}

/// Current durable source binding; an observed epoch is not a later-use permit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceAuthority {
    pub epoch: u64,
    pub identity: SourceIdentity,
}

/// Exact administrative handoff, not a Policy grant or a new logical family.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceRotation {
    pub operation_id: String,
    pub expected_epoch: u64,
    pub next: SourceIdentity,
}
impl SourceRotation {
    pub fn digest(&self) -> Result<String> {
        identifier(&self.operation_id)?;
        self.next.validate()?;
        if self.expected_epoch > MAX_CREDITS {
            return Err(Error::Invalid("source epoch"));
        }
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.source-rotation.v1",
            self,
        ))?))
    }
}

/// Original handoff decision, retained independently of response delivery.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceRotationOutcome {
    Committed,
    Rejected,
}

/// Immutable original result. Its epoch may already be historical.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceRotationReceipt {
    pub operation_id: String,
    pub digest: String,
    pub outcome: SourceRotationOutcome,
    pub authority: SourceAuthority,
}
impl SourceRotationReceipt {
    pub fn validate_for(&self, command: &SourceRotation) -> Result<()> {
        self.authority.identity.validate()?;
        if self.operation_id != command.operation_id
            || self.digest != command.digest()?
            || self.authority.epoch > MAX_CREDITS
            || (self.outcome == SourceRotationOutcome::Committed
                && (self.authority.epoch != command.expected_epoch + 1
                    || self.authority.identity != command.next))
        {
            return Err(Error::Conflict("source rotation receipt binding"));
        }
        Ok(())
    }
}
