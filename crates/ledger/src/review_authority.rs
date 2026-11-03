// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Deployment-owned verification metadata; provisioning does not publish Policy.
//! Its local epoch log is not protection against rollback of the whole store.
use crate::{Ledger, persistence::driver::Connection, store::db};
use weaver_contracts::{Error, Result, ReviewAuthority};
fn decode(epoch: u64, record: &str) -> Result<ReviewAuthority> {
    let authority: ReviewAuthority = weaver_contracts::decode(record.as_bytes())?;
    authority.validate()?;
    if authority.epoch != epoch {
        return Err(Error::Conflict("review authority projection"));
    }
    Ok(authority)
}
pub(crate) fn floor(c: &Connection) -> Result<Option<ReviewAuthority>> {
    let row: Option<(u64, String)> = crate::persistence::maybe(
        c,
        "SELECT epoch,record FROM review_keys ORDER BY epoch DESC LIMIT 1",
        (),
        |r| Ok((crate::store::integer(r, 0)?, r.get(1)?)),
    )
    .map_err(db)?;
    row.map(|(epoch, record)| decode(epoch, &record))
        .transpose()
}
fn required(c: &Connection) -> Result<bool> {
    crate::persistence::one(
        c,
        "SELECT EXISTS(SELECT 1 FROM review_deployment)",
        (),
        |r| r.get(0),
    )
    .map_err(db)
}
fn footprint(c: &Connection) -> Result<bool> {
    crate::persistence::one(c,"SELECT EXISTS(SELECT 1 FROM review_deployment) OR EXISTS(SELECT 1 FROM review_keys) OR EXISTS(SELECT 1 FROM review_authority) OR EXISTS(SELECT 1 FROM authority_review_heads) OR EXISTS(SELECT 1 FROM authority_delta_reviews)",(),|r|r.get(0)).map_err(db)
}
pub(crate) fn current(c: &Connection) -> Result<Option<ReviewAuthority>> {
    let row: Option<(u64, String)> = crate::persistence::maybe(
        c,
        "SELECT epoch,record FROM review_authority WHERE singleton=1",
        (),
        |r| Ok((crate::store::integer(r, 0)?, r.get(1)?)),
    )
    .map_err(db)?;
    let current = row
        .map(|(epoch, record)| decode(epoch, &record))
        .transpose()?;
    if current != floor(c)?
        || current.is_some() != required(c)?
        || (current.is_none() && footprint(c)?)
    {
        return Err(Error::Conflict(
            "review key floor projection missing or stale",
        ));
    }
    Ok(current)
}
impl Ledger {
    /// Deployment-only provisioning: restore the exact retained floor or advance it.
    /// No source RPC credential can call this native configuration API.
    pub fn install_review_authority(&mut self, configured: &ReviewAuthority) -> Result<()> {
        if self.source.is_some() {
            return Err(Error::Denied);
        }
        configured.validate()?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        let floor = floor(&tx)?;
        let required = required(&tx)?;
        if required != floor.is_some() || (!required && footprint(&tx)?) {
            return Err(Error::Conflict(
                "review deployment metadata incomplete; recover original floor",
            ));
        }
        crate::persistence::exec(
            &tx,
            "INSERT INTO review_deployment VALUES(1) ON CONFLICT(singleton) DO NOTHING",
            (),
        )
        .map_err(db)?;
        if let Some(old) = floor
            && old != *configured
            && (configured.epoch <= old.epoch || old.audience != configured.audience)
        {
            return Err(Error::Conflict("review authority rollback or replacement"));
        }
        crate::persistence::exec(
            &tx,
            "INSERT INTO review_keys VALUES(?1,?2) ON CONFLICT(epoch) DO NOTHING",
            crate::persistence::params![
                configured.epoch as i64,
                serde_json::to_string(configured)?
            ],
        )
        .map_err(db)?;
        crate::persistence::exec(&tx,"INSERT INTO review_authority VALUES(1,?1,?2) ON CONFLICT(singleton) DO UPDATE SET epoch=excluded.epoch,record=excluded.record",crate::persistence::params![configured.epoch as i64,serde_json::to_string(configured)?]).map_err(db)?;
        tx.commit().map_err(db)
    }
}
#[cfg(test)]
#[path = "../tests/unit/review_authority.rs"]
mod tests;
