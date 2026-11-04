// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Quota counters share the original provider reservation's deciding transaction.
use crate::{
    persistence::{self, WriteScope},
    store::{db, integer},
};
use weaver_contracts::{Error, MeteringDeployment, Result};

type Scope<'a> = (&'static str, &'a str, u64);

fn scopes<'a>(
    config: &'a MeteringDeployment,
    family: &str,
    principal: &'a str,
) -> Result<Option<[Scope<'a>; 3]>> {
    let Some(quotas) = &config.quotas else {
        return Ok(None);
    };
    let tenant = config.tenant_for(principal).ok_or(Error::Denied)?;
    let key_id = quotas.families.get(family).ok_or(Error::Denied)?;
    let key = quotas
        .keys
        .get(key_id)
        .filter(|k| k.principal == principal)
        .ok_or(Error::Denied)?;
    Ok(Some([
        ("key", key_id, key.limit),
        (
            "user",
            principal,
            *quotas.users.get(principal).ok_or(Error::Denied)?,
        ),
        (
            "tenant",
            tenant,
            *quotas.tenants.get(tenant).ok_or(Error::Denied)?,
        ),
    ]))
}

fn verify(tx: &WriteScope<'_>, scope: Scope<'_>) -> Result<u64> {
    let (kind, id, cap) = scope;
    let total = persistence::one(
        tx,
        "SELECT COALESCE(SUM(r.reserved-COALESCE(a.released,0)),0)
         FROM provider_quota_reservations q
         JOIN provider_runs r ON (r.family,r.node)=(q.family,q.node)
         LEFT JOIN metering_applications a ON (a.family,a.node)=(q.family,q.node)
         WHERE q.kind=?1 AND q.scope=?2",
        [kind, id],
        |row| integer(row, 0),
    )
    .map_err(db)?;
    let held = persistence::maybe(
        tx,
        "SELECT held FROM provider_quota_totals WHERE kind=?1 AND scope=?2",
        [kind, id],
        |row| integer(row, 0),
    )
    .map_err(db)?
    .unwrap_or(0);
    if held != total || held > cap {
        return Err(Error::Conflict("provider quota projection inconsistent"));
    }
    Ok(held)
}

pub(crate) fn reserve(
    tx: &WriteScope<'_>,
    config: &MeteringDeployment,
    family: &str,
    node: &str,
    principal: &str,
    ceiling: u64,
) -> Result<()> {
    let Some(scopes) = scopes(config, family, principal)? else {
        return Ok(());
    };
    for (kind, id, cap) in scopes {
        let before = verify(tx, (kind, id, cap))?;
        let after = before
            .checked_add(ceiling)
            .filter(|n| *n <= cap)
            .ok_or(Error::Conflict("provider quota exhausted"))?;
        let n = persistence::exec(
            tx,
            "INSERT INTO provider_quota_totals VALUES(?1,?2,?3)
             ON CONFLICT(kind,scope) DO UPDATE SET held=excluded.held WHERE held=?4",
            persistence::params![kind.to_owned(), id.to_owned(), after as i64, before as i64],
        )
        .map_err(db)?;
        if n != 1 {
            return Err(Error::Conflict("provider quota CAS lost"));
        }
        persistence::exec(
            tx,
            "INSERT INTO provider_quota_reservations VALUES(?1,?2,?3,?4)",
            [family, node, kind, id],
        )
        .map_err(db)?;
    }
    Ok(())
}

pub(crate) fn require(
    tx: &WriteScope<'_>,
    config: &MeteringDeployment,
    family: &str,
    node: &str,
) -> Result<()> {
    let principal: String = persistence::one(
        tx,
        "SELECT json_extract(record,'$.principal') FROM tasks WHERE family=?1",
        [family],
        |row| row.get(0),
    )
    .map_err(db)?;
    let Some(scopes) = scopes(config, family, &principal)? else {
        return Ok(());
    };
    for (kind, id, cap) in scopes {
        let bound: bool = persistence::one(tx,
            "SELECT EXISTS(SELECT 1 FROM provider_quota_reservations WHERE family=?1 AND node=?2 AND kind=?3 AND scope=?4)",
            [family,node,kind,id], |row| row.get(0)).map_err(db)?;
        if !bound {
            return Err(Error::Conflict("original provider quota missing"));
        }
        verify(tx, (kind, id, cap))?;
    }
    Ok(())
}

pub(crate) fn release(tx: &WriteScope<'_>, family: &str, node: &str, released: u64) -> Result<()> {
    let scopes = persistence::read_all(
        tx,
        "SELECT kind,scope FROM provider_quota_reservations WHERE family=?1 AND node=?2",
        [family, node],
        |row| Ok((row.get::<String>(0)?, row.get::<String>(1)?)),
    )
    .map_err(db)?;
    for (kind, id) in scopes {
        let n = persistence::exec(
            tx,
            "UPDATE provider_quota_totals SET held=held-?1 WHERE kind=?2 AND scope=?3 AND held>=?1",
            persistence::params![released as i64, kind, id],
        )
        .map_err(db)?;
        if n != 1 {
            return Err(Error::Conflict("provider quota release CAS lost"));
        }
    }
    Ok(())
}
