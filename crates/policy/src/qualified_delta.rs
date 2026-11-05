// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bind deployed SPEC qualification to the exact native publication candidate.
use weaver_contracts::{
    AuthorityParent, DeltaDisposition, DeltaReview, Error, Publication, QualifiedDeltaCatalog,
    Result, body_digest,
};

/// Check the actual candidate and parent against independently pinned SPEC output.
/// The digest comes from trusted deployment, never from the publication request.
/// Solver completeness/correctness is distinct from a kernel UNSAT certificate.
pub fn verify_qualified_delta(
    expected: &str,
    change: &Publication,
    parent: Option<&AuthorityParent>,
    evidence: &DeltaReview,
) -> Result<()> {
    if body_digest(&evidence.delta) != expected
        || evidence.review.parent.as_ref() != parent
        || change.expected_revision != parent.map(|p| p.revision)
        || evidence.review.publication.digest != change.digest()?
        || evidence.review.publication.operation_id != change.operation_id
    {
        return Err(Error::Denied);
    }
    let catalog: QualifiedDeltaCatalog = weaver_contracts::decode(evidence.delta.as_bytes())?;
    if catalog.engine != "cedar-poo-spec.exact-error-free-allow"
        || catalog.qualification != "solver-checked"
        || catalog.entries.is_empty()
        || catalog.entries.len() > 64
    {
        return Err(Error::Denied);
    }
    let mut selected = catalog
        .entries
        .iter()
        .filter(|e| e.name == evidence.review.artifact);
    let entry = selected.next().ok_or(Error::Denied)?;
    if selected.next().is_some()
        || entry.environments == 0
        || entry.gains != 0
        || !matches!(
            entry.classification.as_str(),
            "equivalent-in-schema" | "loss-only"
        )
        || entry.after_policy != change.policy
        || entry.schema != change.schema
    {
        return Err(Error::Denied);
    }
    match parent {
        None if evidence.disposition == DeltaDisposition::Bootstrap
            && entry.name == "bootstrap"
            && entry.before_policy == entry.after_policy
            && entry.epoch == 0 => {}
        Some(parent)
            if evidence.disposition == DeltaDisposition::NoExecutionGain
                && entry.name != "bootstrap"
                && entry.epoch == parent.revision
                && body_digest(&entry.before_policy) == parent.policy_digest
                && parent.schema_digest.as_deref() == Some(body_digest(&entry.schema).as_str()) => {
        }
        _ => return Err(Error::Denied),
    }
    crate::validate_typed(&change.policy, &change.schema)
}

#[cfg(test)]
#[path = "../tests/unit/qualified_delta.rs"]
mod tests;
