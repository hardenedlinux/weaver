// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! The committed review association is written in the publication transaction.
//! Effect guards compare its exact projections in one deciding-store snapshot.
use crate::{
    persistence::{driver::Connection, params},
    store::db,
};
use weaver_contracts::{DeltaReview, Error, PublicationReceipt, Result};

pub(crate) fn bind(
    c: &Connection,
    receipt: &PublicationReceipt,
    evidence: &DeltaReview,
) -> Result<()> {
    let issuer =
        crate::review_authority::current(c)?.ok_or(Error::Conflict("review authority missing"))?;
    crate::persistence::exec(c, "INSERT INTO authority_review_heads VALUES(1,?1,?2,?3,?4,?5,?6,?7,?8,?9) ON CONFLICT(singleton) DO UPDATE SET operation_id=excluded.operation_id,digest=excluded.digest,revision=excluded.revision,fence=excluded.fence,reviewer_epoch=excluded.reviewer_epoch,source_epoch=excluded.source_epoch,issuer_record=excluded.issuer_record,review_record=excluded.review_record,delta_record=excluded.delta_record", params![receipt.operation_id.clone(), receipt.digest.clone(), receipt.revision.ok_or(Error::Conflict("committed revision"))? as i64, receipt.fence.ok_or(Error::Conflict("committed fence"))? as i64, evidence.reviewer_epoch as i64, evidence.source_epoch as i64, serde_json::to_string(&issuer)?, serde_json::to_string(&evidence.review)?, serde_json::to_string(evidence)?]).map_err(db)?;
    Ok(())
}

macro_rules! no_review {
    () => {
        r#"NOT EXISTS(SELECT 1 FROM review_keys)
 AND NOT EXISTS(SELECT 1 FROM review_authority)
 AND NOT EXISTS(SELECT 1 FROM review_deployment)
 AND NOT EXISTS(SELECT 1 FROM authority_review_heads)
 AND NOT EXISTS(SELECT 1 FROM authority_delta_reviews)"#
    };
}
macro_rules! valid_review { () => { r#" FROM authority_review_heads h
 JOIN authority a ON a.singleton=1 AND a.revision=h.revision AND a.fence=h.fence
 JOIN authority_schema s ON s.singleton=1
 JOIN authority_publications p ON p.operation_id=h.operation_id AND p.digest=h.digest
 JOIN authority_reviews r ON r.operation_id=h.operation_id AND r.digest=h.digest AND r.record=h.review_record
 JOIN authority_delta_reviews d ON d.operation_id=h.operation_id AND d.reviewer_epoch=h.reviewer_epoch AND d.source_epoch=h.source_epoch AND d.record=h.delta_record
 JOIN review_authority v ON v.singleton=1 AND v.epoch=h.reviewer_epoch AND v.record=h.issuer_record
 JOIN review_keys k ON k.epoch=v.epoch AND k.record=v.record
 WHERE EXISTS(SELECT 1 FROM review_deployment) AND h.singleton=1 AND k.epoch=(SELECT MAX(epoch) FROM review_keys)
 AND json_extract(p.request,'$.policy')=a.policy AND json_extract(p.request,'$.schema')=s.schema
 AND (json_extract(d.record,'$.disposition')!='no_execution_gain' OR json_type(v.record,'$.qualified_catalog')='text')
 AND json_extract(p.receipt,'$.outcome')='committed'
 AND json_extract(p.receipt,'$.revision')=h.revision AND json_extract(p.receipt,'$.fence')=h.fence
"# }; }
const REQUIRE_REVIEW: &str = concat!(
    "SELECT CASE WHEN ",
    no_review!(),
    " THEN 1 ELSE EXISTS(SELECT 1",
    valid_review!(),
    ") END"
);
const LEGACY: &str = concat!("SELECT ", no_review!());
const PREPARE: &str = concat!(
    "SELECT h.operation_id,h.digest,h.revision,h.fence,h.reviewer_epoch,h.source_epoch,h.issuer_record,h.review_record,h.delta_record,p.request,p.receipt,s.schema,a.policy,r.artifact_digest,d.digest",
    valid_review!()
);

/// No historical receipt, raw native publication or missing key projection is a
/// substitute for this current committed association. Source rotation retains
/// a historic publication; any new publication must use the current source.
pub(crate) fn require(c: &Connection) -> Result<()> {
    let admitted: bool =
        crate::persistence::one_current(c, REQUIRE_REVIEW, (), |r| r.get(0)).map_err(db)?;
    if !admitted {
        return Err(Error::Conflict(
            "current reviewed Policy head missing or stale",
        ));
    }
    Ok(())
}

/// The existing review predicate validates this whole candidate in one read.
/// Its exact rows must still match in each deciding transaction.
pub(crate) struct Prepared(Option<Box<ReviewImage>>);

struct ReviewImage {
    operation: String,
    digest: String,
    revision: i64,
    fence: i64,
    reviewer: i64,
    source: i64,
    issuer: String,
    review: String,
    delta: String,
    request: String,
    receipt: String,
    schema: String,
    policy: String,
    artifact_digest: String,
    delta_digest: String,
}

const MATCH_REVIEW: &str = "
SELECT EXISTS(SELECT 1 FROM authority_review_heads WHERE singleton=1
  AND operation_id=?1 AND digest=?2 AND revision=?3 AND fence=?4
  AND reviewer_epoch=?5 AND source_epoch=?6 AND issuer_record=?7
  AND review_record=?8 AND delta_record=?9)
 AND EXISTS(SELECT 1 FROM authority_publications WHERE operation_id=?1
  AND digest=?2 AND request=?10 AND receipt=?11)
 AND EXISTS(SELECT 1 FROM authority_reviews WHERE operation_id=?1 AND digest=?2 AND record=?8 AND artifact_digest=?14)
 AND EXISTS(SELECT 1 FROM authority_delta_reviews WHERE operation_id=?1
  AND reviewer_epoch=?5 AND source_epoch=?6 AND record=?9 AND digest=?15)
 AND EXISTS(SELECT 1 FROM review_authority WHERE singleton=1 AND epoch=?5 AND record=?7)
 AND EXISTS(SELECT 1 FROM review_keys WHERE epoch=?5 AND record=?7)
 AND NOT EXISTS(SELECT 1 FROM review_keys WHERE epoch>?5)
 AND EXISTS(SELECT 1 FROM review_deployment)
 AND EXISTS(SELECT 1 FROM authority_schema WHERE singleton=1 AND schema=?12)
 AND EXISTS(SELECT 1 FROM authority WHERE singleton=1 AND revision=?3 AND fence=?4 AND policy=?13)";

pub(crate) fn prepare(c: &Connection) -> Result<Prepared> {
    if legacy(c)? {
        return Ok(Prepared(None));
    }
    let image = crate::persistence::maybe(c, PREPARE, (), |r| {
        Ok(ReviewImage {
            operation: r.get(0)?,
            digest: r.get(1)?,
            revision: r.get(2)?,
            fence: r.get(3)?,
            reviewer: r.get(4)?,
            source: r.get(5)?,
            issuer: r.get(6)?,
            review: r.get(7)?,
            delta: r.get(8)?,
            request: r.get(9)?,
            receipt: r.get(10)?,
            schema: r.get(11)?,
            policy: r.get(12)?,
            artifact_digest: r.get(13)?,
            delta_digest: r.get(14)?,
        })
    })
    .map_err(db)?
    .ok_or_else(stale)?;
    // The fixed comparison program is compiled before taking the domain lock.
    futures_executor::block_on(c.prepare_cached(MATCH_REVIEW)).map_err(db)?;
    Ok(Prepared(Some(Box::new(image))))
}

fn legacy(c: &Connection) -> Result<bool> {
    crate::persistence::one(c, LEGACY, (), |r| r.get(0)).map_err(db)
}

fn stale() -> Error {
    Error::Conflict("current reviewed Policy head missing or stale")
}

impl Prepared {
    /// Return the exact matched policy, or the legacy profile with no review.
    pub(crate) fn current(
        &self,
        tx: &crate::persistence::WriteScope<'_>,
        revision: u64,
        fence: u64,
    ) -> Result<Option<&str>> {
        let Some(image) = &self.0 else {
            return if legacy(tx)? { Ok(None) } else { Err(stale()) };
        };
        if u64::try_from(image.revision).ok() != Some(revision)
            || u64::try_from(image.fence).ok() != Some(fence)
        {
            return Err(stale());
        }
        let matches: bool = futures_executor::block_on(async {
            let mut statement = tx.prepare_cached(MATCH_REVIEW).await?;
            statement
                .query_row(params![
                    image.operation.as_str(),
                    image.digest.as_str(),
                    image.revision,
                    image.fence,
                    image.reviewer,
                    image.source,
                    image.issuer.as_str(),
                    image.review.as_str(),
                    image.delta.as_str(),
                    image.request.as_str(),
                    image.receipt.as_str(),
                    image.schema.as_str(),
                    image.policy.as_str(),
                    image.artifact_digest.as_str(),
                    image.delta_digest.as_str(),
                ])
                .await?
                .get(0)
        })
        .map_err(db)?;
        if matches {
            Ok(Some(&image.policy))
        } else {
            Err(stale())
        }
    }
}

#[cfg(test)]
#[path = "../tests/unit/reviewed_head.rs"]
mod tests;
