// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Durable proposal barriers share the deciding transaction with every effect guard.
use crate::{Ledger, publication, store::db};
use weaver_contracts::{Error, Publication, PublicationKey, Result};

pub(crate) fn require_resolved(connection: &crate::persistence::driver::Connection) -> Result<()> {
    let pending: bool = crate::persistence::one_current(
        connection,
        "SELECT EXISTS(SELECT 1 FROM authority_pending)",
        (),
        |row| row.get(0),
    )
    .map_err(db)?;
    if pending {
        return Err(Error::Conflict("unresolved Policy proposal"));
    }
    crate::reviewed_head::require(connection)
}

pub(crate) fn require_binding(
    connection: &crate::persistence::driver::Connection,
    change: &Publication,
) -> Result<()> {
    let pending: Option<(String, String)> = crate::persistence::maybe(
        connection,
        "SELECT digest,proposal FROM authority_pending WHERE operation_id=?1",
        crate::persistence::params![change.operation_id.to_owned()],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
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
        if crate::review_authority::current(&self.connection)?.is_some() {
            return self.stage_reviewed_authority(change);
        }
        let digest = change.digest()?;
        weaver_policy::validate_typed(&change.policy, &change.schema)?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        require_binding(&tx, change)?;
        if publication::lookup(&tx, &change.operation_id, &digest)?.is_none() {
            crate::persistence::exec(&tx, "INSERT INTO authority_pending VALUES(?1,?2,?3) ON CONFLICT(operation_id) DO NOTHING", crate::persistence::params![(change.operation_id).to_owned(),(digest).to_owned(),(serde_json::to_string(change)?).to_owned()]).map_err(db)?;
        }
        tx.commit().map_err(db)?;
        Ok(PublicationKey {
            operation_id: change.operation_id.clone(),
            digest,
        })
    }
}
