// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Native review-host boundary. Hashes bind evidence; they do not prove approval.
use crate::{Error, MAX_CREDITS, PublicationKey, Result, body_digest};
use serde::{Deserialize, Serialize};

/// Complete Policy head read by the deciding store, including legacy absent schema.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuthorityParent {
    pub revision: u64,
    pub fence: u64,
    pub policy_digest: String,
    pub schema_digest: Option<String>,
}
impl AuthorityParent {
    pub fn validate(&self) -> Result<()> {
        if self.revision > MAX_CREDITS || self.fence > MAX_CREDITS {
            return Err(Error::Invalid("review parent bounds"));
        }
        digest(&self.policy_digest)?;
        if let Some(schema) = &self.schema_digest {
            digest(schema)?;
        }
        Ok(())
    }
}

/// The trusted review host supplies full immutable upstream evidence bytes.
/// This record is not a self-authenticating approval or a provider-send permit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PublicationReview {
    pub publication: PublicationKey,
    pub parent: Option<AuthorityParent>,
    pub artifact: String,
}
impl PublicationReview {
    pub fn validate(&self) -> Result<()> {
        self.publication.validate()?;
        if let Some(parent) = &self.parent {
            parent.validate()?;
        }
        if self.artifact.is_empty() || self.artifact.len() > 65536 {
            return Err(Error::Invalid("review artifact bounds"));
        }
        Ok(())
    }
    pub fn digest(&self) -> Result<String> {
        self.validate()?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.publication-review.v1",
            &self.publication,
            &self.parent,
            body_digest(&self.artifact),
        ))?))
    }
}

fn digest(value: &str) -> Result<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(Error::Invalid("review commitment"));
    }
    Ok(())
}
