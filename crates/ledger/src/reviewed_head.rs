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

/// No historical receipt, raw native publication or missing key projection is a
/// substitute for this current committed association. Source rotation retains
/// a historic publication; any new publication must use the current source.
pub(crate) fn require(c: &Connection) -> Result<()> {
    let admitted: bool = crate::persistence::one_current(c, r#"
SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM review_keys)
 AND NOT EXISTS(SELECT 1 FROM review_authority)
 AND NOT EXISTS(SELECT 1 FROM review_deployment)
 AND NOT EXISTS(SELECT 1 FROM authority_review_heads)
 AND NOT EXISTS(SELECT 1 FROM authority_delta_reviews) THEN 1 ELSE EXISTS(
 SELECT 1 FROM authority_review_heads h
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
) END
"#, (), |r|r.get(0)).map_err(db)?;
    if !admitted {
        return Err(Error::Conflict(
            "current reviewed Policy head missing or stale",
        ));
    }
    Ok(())
}

#[cfg(test)]
#[path = "../tests/unit/reviewed_head.rs"]
mod tests;
