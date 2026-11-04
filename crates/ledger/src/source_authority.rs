// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Persistent administrative key floor. Whole-store rollback is outside this profile.
#[cfg(test)]
#[path = "../tests/unit/source_authority_storage.rs"]
mod tests;
use crate::{
    Ledger,
    store::{db, integer},
};
use weaver_contracts::{Error, Result, SourceAuthority, SourceIdentity};

pub(crate) fn current(
    connection: &crate::persistence::driver::Connection,
) -> Result<Option<SourceAuthority>> {
    let value: Option<(u64, String)> = crate::persistence::maybe(
        connection,
        "SELECT epoch,record FROM source_authority WHERE singleton=1",
        (),
        |row| Ok((integer(row, 0)?, row.get(1)?)),
    )
    .map_err(db)?;
    value.map(|(epoch,encoded)| {
        let identity:SourceIdentity=weaver_contracts::decode(encoded.as_bytes())?;
        identity.validate()?;
        let matched:bool=crate::persistence::one(connection, "SELECT EXISTS(SELECT 1 FROM source_keys WHERE epoch=?1 AND public_key_sha256=?2 AND certificate_sha256=?3) AND ?1=(SELECT MAX(epoch) FROM source_keys) AND (SELECT COUNT(*) FROM source_keys)=?1+1", crate::persistence::params![(epoch as i64).to_owned(),(identity.public_key_sha256).to_owned(),(identity.certificate_sha256).to_owned()], |r|r.get(0)).map_err(db)?;
        if !matched {return Err(Error::Conflict("source authority prefix mismatch"));}
        Ok(SourceAuthority {epoch,identity})
    }).transpose()
}

pub(crate) fn require(
    connection: &crate::persistence::driver::Connection,
    caller: Option<&SourceIdentity>,
) -> Result<()> {
    if let Some(caller) = caller {
        let authority = current(connection)?.ok_or(Error::Denied)?;
        if authority.identity != *caller {
            return Err(Error::Denied);
        }
    }
    Ok(())
}

pub(crate) fn write(
    connection: &crate::persistence::driver::Connection,
    authority: &SourceAuthority,
) -> Result<()> {
    crate::persistence::exec(
        connection,
        "INSERT INTO source_keys VALUES(?1,?2,?3)",
        crate::persistence::params![
            (authority.identity.public_key_sha256).to_owned(),
            (authority.epoch as i64).to_owned(),
            (authority.identity.certificate_sha256).to_owned()
        ],
    )
    .map_err(db)?;
    crate::persistence::exec(connection, "INSERT INTO source_authority VALUES(1,?1,?2) ON CONFLICT(singleton) DO UPDATE SET epoch=excluded.epoch,record=excluded.record", crate::persistence::params![(authority.epoch as i64).to_owned(),(serde_json::to_string(&authority.identity)?).to_owned()]).map_err(db)?;
    Ok(())
}

// Enrollment is the only caller. Discover all durable application tables in
// this deciding transaction, including residual projections and future schema
// extensions. Temporary aliases cannot hide rows in the main ledger namespace.
fn has_application_rows(connection: &crate::persistence::driver::Connection) -> Result<bool> {
    let tables = crate::persistence::read_all(connection,"SELECT name FROM main.sqlite_schema WHERE type='table' AND name NOT GLOB 'sqlite_*' ORDER BY name",(),|r|r.get::<String>(0)).map_err(db)?;
    for table in tables {
        // An independently provisioned verifier is deployment metadata, not
        // application ownership. Invalid metadata still refuses enrollment.
        if matches!(
            table.as_str(),
            "review_authority" | "review_keys" | "review_deployment"
        ) {
            crate::review_authority::current(connection)?;
            continue;
        }
        if matches!(
            table.as_str(),
            "provider_oauth_deployment" | "provider_oauth_witness"
        ) {
            if let Some(config) = crate::provider_oauth::deployment(connection)? {
                config.validate()?;
                crate::provider_oauth_witness::require_current(connection, &config)?;
            }
            continue;
        }
        if table == "metering_deployment" {
            if let Some(config) = crate::metering::deployment(connection)? {
                config.validate()?;
            }
            continue;
        }
        if crate::persistence::engine_metadata(connection, &table).map_err(db)? {
            continue;
        }
        let identifier = table.replace('"', "\"\"");
        let occupied: bool = crate::persistence::one(
            connection,
            &format!("SELECT EXISTS(SELECT 1 FROM main.\"{identifier}\")"),
            (),
            |row| row.get(0),
        )
        .map_err(db)?;
        if occupied {
            return Ok(true);
        }
    }
    Ok(false)
}

fn ensure(ledger: &mut Ledger, caller: &SourceIdentity) -> Result<()> {
    caller.validate()?;
    if current(&ledger.connection)?.is_some() {
        return require(&ledger.connection, Some(caller));
    }
    let tx = crate::persistence::begin(&mut ledger.connection).map_err(db)?;
    if current(&tx)?.is_none() {
        if has_application_rows(&tx)? {
            return Err(Error::Conflict(
                "source enrollment requires an empty unowned store",
            ));
        }
        write(
            &tx,
            &SourceAuthority {
                epoch: 0,
                identity: caller.clone(),
            },
        )?;
    }
    require(&tx, Some(caller))?;
    tx.commit().map_err(db)
}

struct Scope<'a> {
    ledger: &'a mut Ledger,
}
impl Drop for Scope<'_> {
    fn drop(&mut self) {
        self.ledger.source = None;
    }
}

impl Ledger {
    /// RPC host supplies identity derived from actual authenticated mTLS and bearer.
    /// Every source mutator rechecks it inside its own deciding transaction.
    /// Local trusted-host callers remain a separate explicit API profile.
    pub fn with_authenticated_source<T>(
        &mut self,
        caller: &SourceIdentity,
        run: impl FnOnce(&mut Ledger) -> Result<T>,
    ) -> Result<T> {
        if self.source.is_some() {
            return Err(Error::Conflict("nested source identity context"));
        }
        ensure(self, caller)?;
        self.source = Some(caller.clone());
        let scope = Scope { ledger: self };
        run(scope.ledger)
    }
    /// Current observation is not permission to perform a later source mutation.
    pub fn source_authority(&self) -> Result<Option<SourceAuthority>> {
        require(&self.connection, self.source.as_ref())?;
        current(&self.connection)
    }
}
