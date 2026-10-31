//! Durable proposal barriers share the deciding transaction with every effect guard.
use crate::{Ledger, publication, store::db};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use weaver_contracts::{Error, Publication, PublicationKey, Result};

pub(crate) fn require_resolved(connection: &Connection) -> Result<()> {
    let pending: bool = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM authority_pending)",
            [],
            |row| row.get(0),
        )
        .map_err(db)?;
    if pending {
        return Err(Error::Conflict("unresolved Policy proposal"));
    }
    Ok(())
}

pub(crate) fn require_binding(connection: &Connection, change: &Publication) -> Result<()> {
    let pending: Option<(String, String)> = connection
        .query_row(
            "SELECT digest,proposal FROM authority_pending WHERE operation_id=?1",
            [&change.operation_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(db)?;
    if let Some((digest, body)) = pending {
        let original: Publication = weaver_contracts::decode(body.as_bytes())?;
        if original != *change || original.digest()? != digest {
            return Err(Error::Conflict("pending Policy identity already bound"));
        }
    }
    Ok(())
}

impl Ledger {
    /// Acknowledgment means durable staging or an already recorded exact decision.
    /// It never asserts that this proposal committed, or that authority is current.
    pub fn stage_authority(&mut self, change: &Publication) -> Result<PublicationKey> {
        let digest = change.digest()?;
        weaver_policy::validate_typed(&change.policy, &change.schema)?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        require_binding(&tx, change)?;
        if publication::lookup(&tx, &change.operation_id, &digest)?.is_none() {
            tx.execute("INSERT INTO authority_pending VALUES(?1,?2,?3) ON CONFLICT(operation_id) DO NOTHING",
                params![change.operation_id, digest, serde_json::to_string(change)?]).map_err(db)?;
        }
        tx.commit().map_err(db)?;
        Ok(PublicationKey {
            operation_id: change.operation_id.clone(),
            digest,
        })
    }
}
