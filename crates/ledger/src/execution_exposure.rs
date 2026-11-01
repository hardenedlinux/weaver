//! One deciding projection for all retained execution kinds; never repairs authority.
use crate::store::db;
use rusqlite::{Transaction, params};
use weaver_contracts::{Error, MessageBinding, Proposal, ProviderPlan, Result};

/// Read every retained family reservation and its original kind under the writer.
/// Completion is observational: none of these execution paths authorizes refunds.
pub(crate) fn require_family(tx: &Transaction<'_>, family: &str) -> Result<()> {
    let retained: bool = tx
        .query_row(
            "WITH retained AS (
           SELECT node,reserved,'request' AS kind FROM operations WHERE family=?1
           UNION ALL SELECT node,reserved,'stream' FROM stream_messages WHERE family=?1
           UNION ALL SELECT node,reserved,'stream' FROM provider_runs WHERE family=?1
         )
         SELECT EXISTS(SELECT 1 FROM tasks t WHERE t.family=?1
           AND t.budget=json_extract(t.record,'$.budget')
           AND t.held<=t.budget
           AND t.held=COALESCE((SELECT SUM(reserved) FROM retained),0)
           AND NOT EXISTS(SELECT 1 FROM retained r LEFT JOIN execution_claims c
             ON c.family=?1 AND c.node=r.node AND c.kind=r.kind WHERE c.node IS NULL))",
            [family],
            |row| row.get(0),
        )
        .map_err(db)?;
    require(retained)
}

pub(crate) fn request(tx: &Transaction<'_>, proposal: &Proposal) -> Result<()> {
    let matches: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM operations WHERE family=?1 AND node=?2 AND reserved=?3)",
            params![proposal.family, proposal.node, proposal.ceiling as i64],
            |row| row.get(0),
        )
        .map_err(db)?;
    require(matches)?;
    require_family(tx, &proposal.family)
}

pub(crate) fn message(tx: &Transaction<'_>, binding: &MessageBinding) -> Result<()> {
    let matches: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM stream_messages WHERE family=?1 AND node=?2 AND message=?3 AND reserved=?4)",
        params![binding.family, binding.node, binding.message, binding.ceiling as i64], |row| row.get(0),
    ).map_err(db)?;
    require(matches)?;
    require_family(tx, &binding.family)
}

pub(crate) fn provider(tx: &Transaction<'_>, plan: &ProviderPlan) -> Result<()> {
    let matches: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM provider_runs WHERE family=?1 AND node=?2 AND reserved=?3)",
        params![plan.family, plan.node, plan.ceiling as i64], |row| row.get(0),
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
