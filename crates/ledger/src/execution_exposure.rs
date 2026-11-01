//! One deciding projection for all retained execution kinds; never repairs authority.
use crate::store::db;
use rusqlite::{Transaction, params};
use weaver_contracts::{Error, MessageBinding, Proposal, ProviderPlan, Result};

pub(crate) enum ClaimKind {
    Request,
    Stream,
    Provider,
}

pub(crate) struct ReservationClaim<'a> {
    pub family: &'a str,
    pub node: &'a str,
    pub kind: ClaimKind,
    pub member: &'a str,
    pub digest: &'a str,
    pub ceiling: u64,
}

/// Append the original member under the same transaction as its row and hold.
/// Only distinct stream messages may extend an existing logical node claim.
pub(crate) fn retain(tx: &Transaction<'_>, claim: ReservationClaim<'_>) -> Result<()> {
    let kind = match claim.kind {
        ClaimKind::Request => "request",
        ClaimKind::Stream => "stream",
        ClaimKind::Provider => "provider",
    };
    let changed = tx.execute(
        "INSERT INTO execution_claims(family,node,kind,reservations)
         VALUES(?1,?2,?3,json_object(?4,json_object('digest',?5,'ceiling',?6)))
         ON CONFLICT(family,node) DO UPDATE SET reservations=json_patch(execution_claims.reservations,excluded.reservations)
         WHERE execution_claims.kind='stream' AND excluded.kind='stream'
           AND NOT EXISTS(SELECT 1 FROM json_each(execution_claims.reservations) WHERE key=?4)",
        params![claim.family, claim.node, kind, claim.member, claim.digest, claim.ceiling as i64],
    ).map_err(db)?;
    if changed != 1 {
        return Err(Error::Conflict("logical reservation already claimed"));
    }
    Ok(())
}

/// Read every retained family reservation and its original kind under the writer.
/// Completion is observational: none of these execution paths authorizes refunds.
pub(crate) fn require_family(tx: &Transaction<'_>, family: &str) -> Result<()> {
    let retained: bool = tx
        .query_row(
            "WITH retained AS MATERIALIZED (
           SELECT node,'' AS member,digest,reserved,'request' AS kind,json_extract(proposal,'$.ceiling') AS original FROM operations WHERE family=?1
           UNION ALL SELECT node,message,digest,reserved,'stream',json_extract(proposal,'$.ceiling') FROM stream_messages WHERE family=?1
           UNION ALL SELECT node,'',digest,reserved,'provider',json_extract(plan,'$.ceiling') FROM provider_runs WHERE family=?1
         ), committed AS MATERIALIZED (
           SELECT c.node,c.kind,j.key AS member,json_extract(j.value,'$.digest') AS digest,
             json_extract(j.value,'$.ceiling') AS original
           FROM execution_claims c,json_each(c.reservations) j WHERE c.family=?1
         )
         SELECT EXISTS(SELECT 1 FROM tasks t WHERE t.family=?1
           AND t.budget=json_extract(t.record,'$.budget')
           AND t.held<=t.budget
           AND NOT EXISTS(SELECT 1 FROM execution_claims c WHERE c.family=?1
             AND NOT EXISTS(SELECT 1 FROM committed m WHERE m.node=c.node AND m.kind=c.kind))
           AND NOT EXISTS(SELECT 1 FROM committed c LEFT JOIN retained r
             ON r.node=c.node AND r.kind=c.kind AND r.member=c.member AND r.digest=c.digest AND r.reserved=c.original
             WHERE r.node IS NULL)
           AND NOT EXISTS(SELECT 1 FROM retained WHERE reserved IS NOT original)
           AND t.held=COALESCE((SELECT SUM(reserved) FROM retained),0)
           AND NOT EXISTS(SELECT 1 FROM retained r LEFT JOIN committed c
             ON c.node=r.node AND c.kind=r.kind AND c.member=r.member AND c.digest=r.digest AND c.original=r.reserved
             WHERE c.node IS NULL))",
            [family],
            |row| row.get(0),
        )
        .map_err(db)?;
    require(retained)
}

pub(crate) fn request(tx: &Transaction<'_>, proposal: &Proposal) -> Result<()> {
    let matches: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM operations WHERE family=?1 AND node=?2 AND reserved=?3 AND digest=?4)",
            params![proposal.family, proposal.node, proposal.ceiling as i64, proposal.digest()?],
            |row| row.get(0),
        )
        .map_err(db)?;
    require(matches)?;
    require_family(tx, &proposal.family)
}

pub(crate) fn message(tx: &Transaction<'_>, binding: &MessageBinding) -> Result<()> {
    let matches: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM stream_messages WHERE family=?1 AND node=?2 AND message=?3 AND reserved=?4 AND digest=?5)",
        params![binding.family, binding.node, binding.message, binding.ceiling as i64, binding.digest()?], |row| row.get(0),
    ).map_err(db)?;
    require(matches)?;
    require_family(tx, &binding.family)
}

pub(crate) fn provider(tx: &Transaction<'_>, plan: &ProviderPlan, digest: &str) -> Result<()> {
    let matches: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM provider_runs WHERE family=?1 AND node=?2 AND reserved=?3 AND digest=?4)",
        params![plan.family, plan.node, plan.ceiling as i64, digest], |row| row.get(0),
    ).map_err(db)?;
    require(matches)?;
    require_family(tx, &plan.family)
}

fn require(retained: bool) -> Result<()> {
    if retained {
        Ok(())
    } else {
        Err(Error::Conflict(
            "original claims or shared execution exposure not retained",
        ))
    }
}
