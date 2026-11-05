// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Registry admission only. No Policy, fence, task, budget or execution is changed.
//! The independent producer is responsible for actual SPEC Delta qualification.
use crate::{
    Ledger,
    persistence::{driver::Connection, params},
    publication_review as review,
    store::db,
};
use weaver_contracts::{DeltaReview, Error, PublicationKey, PublicationReviewContext, Result};

pub(crate) fn registered(
    c: &Connection,
    key: &PublicationKey,
    reviewer: u64,
    source: u64,
) -> Result<Option<DeltaReview>> {
    let row:Option<(String,String)>=crate::persistence::maybe(c,
        "SELECT digest,record FROM authority_delta_reviews WHERE operation_id=?1 AND reviewer_epoch=?2 AND source_epoch=?3",
        params![key.operation_id.clone(),reviewer as i64,source as i64],|r|Ok((r.get(0)?,r.get(1)?))).map_err(db)?;
    row.map(|(digest, record)| {
        let e: DeltaReview = weaver_contracts::decode(record.as_bytes())?;
        e.validate()?;
        if e.review.publication != *key
            || e.signing_digest()? != digest
            || e.reviewer_epoch != reviewer
            || e.source_epoch != source
        {
            return Err(Error::Conflict("Delta registration projection"));
        }
        Ok(e)
    })
    .transpose()
}

/// Revalidate the authenticated approval against the deciding transaction, not
/// the earlier registration response. Native hosts without deployment metadata
/// retain their existing trusted-host API; the served profile provisions a key.
pub(crate) fn require_current(c: &Connection, key: &PublicationKey) -> Result<Option<DeltaReview>> {
    let Some(issuer) = crate::review_authority::current(c)? else {
        return Ok(None);
    };
    let source = crate::source_authority::current(c)?.ok_or(Error::Denied)?;
    let evidence = registered(c, key, issuer.epoch, source.epoch)?.ok_or(Error::Conflict(
        "current authenticated Delta review missing",
    ))?;
    weaver_policy::verify_delta_review(&issuer, &source, &evidence)?;
    verify_semantics(c, key, &issuer, &evidence)?;
    review::require_approved(c, key)?;
    if review::registered(c, key)?.as_ref() != Some(&evidence.review) {
        return Err(Error::Conflict("Delta review registration binding"));
    }
    Ok(Some(evidence))
}

/// Validate qualification under the same snapshot used for registry/publication.
fn verify_semantics(
    c: &Connection,
    key: &PublicationKey,
    issuer: &weaver_contracts::ReviewAuthority,
    e: &DeltaReview,
) -> Result<()> {
    use weaver_contracts::DeltaDisposition;
    if e.disposition == DeltaDisposition::ExplicitApproval {
        return Ok(());
    }
    let Some(pin) = issuer.qualified_catalog.as_deref() else {
        return if e.disposition == DeltaDisposition::Bootstrap {
            Ok(())
        } else {
            Err(Error::Conflict(
                "NoGain requires deployment-qualified SPEC output",
            ))
        };
    };
    let command:String=crate::persistence::one(c,"SELECT proposal FROM authority_pending WHERE operation_id=?1 AND digest=?2 UNION ALL SELECT request FROM authority_publications WHERE operation_id=?1 AND digest=?2 LIMIT 1",params![key.operation_id.clone(),key.digest.clone()],|r|r.get(0)).map_err(db)?;
    let change: weaver_contracts::Publication = weaver_contracts::decode(command.as_bytes())?;
    weaver_policy::verify_qualified_delta(pin, &change, e.review.parent.as_ref(), e)
}

impl Ledger {
    pub fn publication_review_context(
        &self,
        key: &PublicationKey,
    ) -> Result<PublicationReviewContext> {
        crate::source_authority::require(&self.connection, self.source.as_ref())?;
        Ok(PublicationReviewContext {
            publication: key.clone(),
            parent: self.required_review_parent(key)?,
            reviewer: crate::review_authority::current(&self.connection)?
                .ok_or(Error::Conflict("review issuer not configured"))?,
            source: crate::source_authority::current(&self.connection)?.ok_or(Error::Denied)?,
        })
    }
    /// Authenticate producer qualification and atomically retain its exact evidence.
    /// A signature is not a Delta proof; SPEC correctness remains a producer premise.
    pub fn register_delta_review(&mut self, e: &DeltaReview) -> Result<String> {
        e.validate()?;
        let key = &e.review.publication;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let issuer = crate::review_authority::current(&tx)?
            .ok_or(Error::Conflict("review issuer not configured"))?;
        let source = crate::source_authority::current(&tx)?.ok_or(Error::Denied)?;
        weaver_policy::verify_delta_review(&issuer, &source, e)?;
        verify_semantics(&tx, key, &issuer, e)?;
        if let Some(old) = registered(&tx, key, issuer.epoch, source.epoch)? {
            if old != *e {
                return Err(Error::Conflict("Delta registration already bound"));
            }
        } else {
            if crate::publication::lookup(&tx, &key.operation_id, &key.digest)?.is_some() {
                return Err(Error::Conflict(
                    "historical outcome cannot gain a new approval",
                ));
            }
            let captured =
                review::requirement(&tx, key)?.ok_or(Error::Conflict("review not required"))?;
            let parent: Option<weaver_contracts::AuthorityParent> =
                weaver_contracts::decode(captured.as_bytes())?;
            if parent != e.review.parent || review::parent(&tx)? != parent {
                return Err(Error::Conflict("review deciding parent changed"));
            }
            if let Some(old) = review::registered(&tx, key)? {
                if old != e.review {
                    return Err(Error::Conflict("review already bound"));
                }
            } else {
                review::register_current(&tx, &e.review, &e.review.digest()?)?;
            }
            crate::persistence::exec(
                &tx,
                "INSERT INTO authority_delta_reviews VALUES(?1,?2,?3,?4,?5)",
                params![
                    key.operation_id.clone(),
                    issuer.epoch as i64,
                    source.epoch as i64,
                    e.signing_digest()?,
                    serde_json::to_string(e)?
                ],
            )
            .map_err(db)?;
        }
        tx.commit().map_err(db)?;
        e.review.digest()
    }
}

#[cfg(test)]
#[path = "../tests/unit/delta_registration.rs"]
mod tests;
