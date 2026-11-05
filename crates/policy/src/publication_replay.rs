// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Reuse SPEC's exact schema-bound replay. Finite replay never proves no-gain.
use cedar_poo_runtime::{SchemaBoundReceipt, ValidatedManifest};
use serde::Deserialize;
use weaver_contracts::{
    AuthorityParent, Error, Publication, PublicationKey, PublicationReview, Result, body_digest,
};

/// Original full predecessor bytes supplied as evidence, checked against the
/// authority-owned captured head. These labels are not source authentication.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReplayPredecessor {
    case: String,
    policy: String,
    schema: String,
}

/// Transport envelope around upstream types, not another Policy/review language.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CandidateReplay {
    manifest: ValidatedManifest,
    receipts: Vec<SchemaBoundReceipt>,
    candidate_case: String,
    predecessor: Option<ReplayPredecessor>,
}

/// Observed finite evidence, not an approval, no-gain proof or execution grant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublicationReplayCheck {
    pub publication: PublicationKey,
    pub artifact_digest: String,
    pub candidate_cases: usize,
    pub parent: Option<AuthorityParent>,
    pub parent_cases: usize,
}

/// Check actual upstream receipts and bind the exact candidate Policy IDs/bodies
/// and schema to the original publication and authority-owned captured parent.
/// The host must read captured_parent from its immutable review requirement;
/// caller-supplied review metadata cannot select it. Producer authentication,
/// complete semantic Profile/source selection and Delta qualification remain Host duties.
pub fn verify_publication_replay(
    change: &Publication,
    review: &PublicationReview,
    captured_parent: Option<&AuthorityParent>,
) -> Result<PublicationReplayCheck> {
    review.validate()?;
    let publication = PublicationKey {
        operation_id: change.operation_id.clone(),
        digest: change.digest()?,
    };
    if review.publication != publication {
        return Err(Error::Conflict("replay publication binding"));
    }
    if review.parent.as_ref() != captured_parent
        || change.expected_revision != captured_parent.map(|p| p.revision)
    {
        return Err(Error::Conflict("replay authority-owned parent"));
    }
    let artifact: CandidateReplay = weaver_contracts::decode(review.artifact.as_bytes())?;
    if artifact.manifest.cases.is_empty()
        || artifact.manifest.cases.len() > 64
        || artifact.receipts.len() != artifact.manifest.cases.len()
    {
        return Err(Error::Invalid("replay case bounds"));
    }
    let schema: serde_json::Value = weaver_contracts::decode(change.schema.as_bytes())?;
    if schema != *artifact.manifest.schema {
        return Err(Error::Conflict("replay candidate schema"));
    }
    let candidate_cases = bind_image(&change.policy, &artifact.candidate_case, &artifact)?;
    let parent_cases = bind_predecessor(captured_parent, &artifact)?;
    cedar_poo_runtime::verify_validated_replay_receipts(&artifact.manifest, &artifact.receipts)
        .map_err(Error::Policy)?;
    Ok(PublicationReplayCheck {
        publication,
        artifact_digest: review.digest()?,
        candidate_cases,
        parent: captured_parent.cloned(),
        parent_cases,
    })
}

fn bind_predecessor(parent: Option<&AuthorityParent>, artifact: &CandidateReplay) -> Result<usize> {
    match (parent, artifact.predecessor.as_ref()) {
        (None, None) => Ok(0),
        (Some(parent), Some(before)) => {
            parent.validate()?;
            if before.policy.len() > 65536
                || before.schema.len() > 65536
                || body_digest(&before.policy) != parent.policy_digest
                || parent.schema_digest.as_deref() != Some(body_digest(&before.schema).as_str())
            {
                return Err(Error::Conflict("replay predecessor bytes"));
            }
            let schema: serde_json::Value = weaver_contracts::decode(before.schema.as_bytes())?;
            if schema != *artifact.manifest.schema {
                return Err(Error::Conflict("replay predecessor schema"));
            }
            bind_image(&before.policy, &before.case, artifact)
        }
        _ => Err(Error::Conflict("replay predecessor presence")),
    }
}

fn bind_image(policy: &str, selected_case: &str, artifact: &CandidateReplay) -> Result<usize> {
    let case = artifact
        .manifest
        .cases
        .iter()
        .find(|c| c.name == selected_case)
        .ok_or(Error::Conflict("replay candidate case missing"))?;
    // Upstream admission checks declared IDs, strict schema and entity parsing;
    // its rendered sources are intentionally NOT joined into a textual PolicySet.
    // Cedar text reparsing renames IDs, which would change reasons/diagnostics.
    cedar_poo_runtime::render_validated_policy_sources(&artifact.manifest, selected_case)
        .map_err(Error::Policy)?;
    let expected = cedar_poo_runtime::load_policy_set(&case.policies)
        .map_err(Error::Policy)?
        .to_json()
        .map_err(|_| Error::Policy("candidate Policy encoding".into()))?;
    let actual = crate::compiled::with_policy(policy, |p| {
        p.clone()
            .to_json()
            .map_err(|_| Error::Policy("publication Policy encoding".into()))
    })??;
    if actual != expected {
        return Err(Error::Conflict("replay candidate Policy identity"));
    }
    Ok(artifact
        .manifest
        .cases
        .iter()
        .filter(|c| c.revision == case.revision)
        .count())
}
