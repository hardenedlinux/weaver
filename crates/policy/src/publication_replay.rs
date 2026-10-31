//! Reuse SPEC's exact schema-bound replay. Finite replay never proves no-gain.
use cedar_poo_runtime::{SchemaBoundReceipt, ValidatedManifest};
use serde::Deserialize;
use weaver_contracts::{Error, Publication, PublicationKey, PublicationReview, Result};

/// Transport envelope around upstream types, not another Policy/review language.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CandidateReplay {
    manifest: ValidatedManifest,
    receipts: Vec<SchemaBoundReceipt>,
    candidate_case: String,
}

/// Observed finite evidence, not an approval, no-gain proof or execution grant.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PublicationReplayCheck {
    pub publication: PublicationKey,
    pub artifact_digest: String,
    pub candidate_cases: usize,
}

/// Check actual upstream receipts and bind the exact candidate Policy IDs/bodies
/// and schema to the original publication. Producer authentication, independent
/// semantic parent selection and actual Delta qualification remain Host duties.
pub fn verify_publication_replay(
    change: &Publication,
    review: &PublicationReview,
) -> Result<PublicationReplayCheck> {
    review.validate()?;
    let publication = PublicationKey {
        operation_id: change.operation_id.clone(),
        digest: change.digest()?,
    };
    if review.publication != publication {
        return Err(Error::Conflict("replay publication binding"));
    }
    let artifact: CandidateReplay = weaver_contracts::decode(review.artifact.as_bytes())?;
    if artifact.manifest.cases.is_empty()
        || artifact.manifest.cases.len() > 64
        || artifact.receipts.len() != artifact.manifest.cases.len()
    {
        return Err(Error::Invalid("replay case bounds"));
    }
    let schema: serde_json::Value = weaver_contracts::decode(change.schema.as_bytes())?;
    if schema != artifact.manifest.schema {
        return Err(Error::Conflict("replay candidate schema"));
    }
    let candidate_cases = bind_candidate(change, &artifact)?;
    cedar_poo_runtime::verify_validated_replay_receipts(&artifact.manifest, &artifact.receipts)
        .map_err(Error::Policy)?;
    Ok(PublicationReplayCheck {
        publication,
        artifact_digest: review.digest()?,
        candidate_cases,
    })
}

fn bind_candidate(change: &Publication, artifact: &CandidateReplay) -> Result<usize> {
    let case = artifact
        .manifest
        .cases
        .iter()
        .find(|c| c.name == artifact.candidate_case)
        .ok_or(Error::Conflict("replay candidate case missing"))?;
    // Upstream admission checks declared IDs, strict schema and entity parsing;
    // its rendered sources are intentionally NOT joined into a textual PolicySet.
    // Cedar text reparsing renames IDs, which would change reasons/diagnostics.
    cedar_poo_runtime::render_validated_policy_sources(
        &artifact.manifest,
        &artifact.candidate_case,
    )
    .map_err(Error::Policy)?;
    let expected = cedar_poo_runtime::load_policy_set(&case.policies)
        .map_err(Error::Policy)?
        .to_json()
        .map_err(|_| Error::Policy("candidate Policy encoding".into()))?;
    let actual = crate::compiled::with_policy(&change.policy, |p| {
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
