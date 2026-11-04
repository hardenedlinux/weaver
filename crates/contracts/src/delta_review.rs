// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authenticated upstream review transport; signatures do not establish Delta soundness.
use crate::{Error, MAX_CREDITS, PublicationReview, Result, body_digest, identifier};
use serde::{Deserialize, Serialize};

/// Deployment-owned review key. Source RPC callers cannot replace this authority.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReviewAuthority {
    pub audience: String,
    pub epoch: u64,
    pub public_key: String,
    pub allow_expansion: bool,
    /// Independent deployment commitment to actual SPEC qualification output.
    #[serde(default)]
    pub qualified_catalog: Option<String>,
}
impl ReviewAuthority {
    pub fn validate(&self) -> Result<()> {
        identifier(&self.audience)?;
        if self.epoch > MAX_CREDITS {
            return Err(Error::Invalid("review authority epoch"));
        }
        if let Some(digest) = &self.qualified_catalog {
            hexadecimal(digest, 64)?;
        }
        hexadecimal(&self.public_key, 64)
    }
}

/// Producer-qualified Delta disposition; a label alone establishes no semantic proof.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeltaDisposition {
    Bootstrap,
    NoExecutionGain,
    ExplicitApproval,
}

/// The configured producer attests to SPEC analysis and its release decision.
/// Rust authenticates exact bindings; SPEC analysis/replay is a producer obligation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeltaReview {
    pub review: PublicationReview,
    pub audience: String,
    pub reviewer_epoch: u64,
    pub source_epoch: u64,
    pub source_identity_digest: String,
    pub disposition: DeltaDisposition,
    pub delta: String,
    pub signature: String,
}
impl DeltaReview {
    pub fn signing_digest(&self) -> Result<String> {
        self.review.validate()?;
        identifier(&self.audience)?;
        hexadecimal(&self.source_identity_digest, 64)?;
        if self.reviewer_epoch > MAX_CREDITS
            || self.source_epoch > MAX_CREDITS
            || self.delta.is_empty()
            || self.delta.len() > 65536
        {
            return Err(Error::Invalid("Delta evidence bounds"));
        }
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.authority-delta-review.v1",
            &self.audience,
            self.reviewer_epoch,
            self.source_epoch,
            &self.source_identity_digest,
            self.review.digest()?,
            self.disposition,
            body_digest(&self.delta),
        ))?))
    }
    pub fn validate(&self) -> Result<()> {
        self.signing_digest()?;
        hexadecimal(&self.signature, 128)
    }
}

fn hexadecimal(value: &str, length: usize) -> Result<()> {
    if value.len() != length
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(Error::Invalid("review hexadecimal binding"));
    }
    Ok(())
}

/// Source/parent/issuer observations for an already staged original, never a permit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublicationReviewContext {
    pub publication: crate::PublicationKey,
    pub parent: Option<crate::AuthorityParent>,
    pub reviewer: ReviewAuthority,
    pub source: crate::SourceAuthority,
}
