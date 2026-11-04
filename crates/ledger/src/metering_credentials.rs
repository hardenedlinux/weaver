// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    Ledger,
    persistence::{self, WriteScope},
    store::{db, integer},
};
use weaver_contracts::{Error, MAX_CREDITS, MeteringDeployment, Result, SourceIdentity};

pub(crate) fn require(
    tx: &WriteScope<'_>,
    config: &MeteringDeployment,
    caller: &SourceIdentity,
    tenant: &str,
    issuer: &str,
) -> Result<()> {
    if config
        .tenants
        .get(tenant)
        .is_none_or(|rule| rule.issuer != issuer)
    {
        return Err(Error::Denied);
    }
    let record: Option<String> = persistence::maybe(
        tx,
        "SELECT record FROM metering_credentials WHERE tenant=?1 ORDER BY epoch DESC LIMIT 1",
        [tenant],
        |row| row.get(0),
    )
    .map_err(db)?;
    if let Some(record) = record {
        let current: SourceIdentity = weaver_contracts::decode(record.as_bytes())?;
        return if current == *caller {
            Ok(())
        } else {
            Err(Error::Denied)
        };
    }
    if config.require_terminal_usage {
        return Err(Error::Denied);
    }
    // Existing external-evidence deployments can retain their original source
    // transport until this tenant enrolls its independent meter.
    crate::source_authority::require(tx, Some(caller))
}

impl Ledger {
    pub fn rotate_meter_credential(
        &mut self,
        tenant: &str,
        issuer: &str,
        expected: u64,
        next: &SourceIdentity,
    ) -> Result<u64> {
        next.validate()?;
        let epoch = expected
            .checked_add(1)
            .filter(|n| *n <= MAX_CREDITS)
            .ok_or(Error::Invalid("meter credential epoch"))?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let config = crate::metering::deployment(&tx)?.ok_or(Error::Denied)?;
        if config
            .tenants
            .get(tenant)
            .is_none_or(|rule| rule.issuer != issuer)
        {
            return Err(Error::Denied);
        }
        let record = serde_json::to_string(next)?;
        let prior: Option<String> = persistence::maybe(
            &tx,
            "SELECT record FROM metering_credentials WHERE tenant=?1 AND epoch=?2",
            persistence::params![tenant.to_owned(), epoch as i64],
            |row| row.get(0),
        )
        .map_err(db)?;
        if let Some(prior) = prior {
            return if prior == record {
                Ok(epoch)
            } else {
                Err(Error::Conflict("meter credential epoch already bound"))
            };
        }
        let current = persistence::one(
            &tx,
            "SELECT COALESCE(MAX(epoch),0) FROM metering_credentials WHERE tenant=?1",
            [tenant],
            |row| integer(row, 0),
        )
        .map_err(db)?;
        if current != expected {
            return Err(Error::Conflict("stale meter credential epoch"));
        }
        let reused: bool = persistence::one(&tx, "SELECT EXISTS(SELECT 1 FROM source_keys WHERE certificate_sha256=?1 OR public_key_sha256=?3) OR EXISTS(SELECT 1 FROM metering_credentials WHERE certificate=?1 OR credential=?2 OR public_key=?3)",
            [next.certificate_sha256.as_str(), next.credential_sha256.as_str(), next.public_key_sha256.as_str()], |row| row.get(0)).map_err(db)?;
        if reused {
            return Err(Error::Denied);
        }
        persistence::exec(
            &tx,
            "INSERT INTO metering_credentials VALUES(?1,?2,?3,?4,?5,?6)",
            persistence::params![
                tenant.to_owned(),
                epoch as i64,
                next.certificate_sha256.clone(),
                next.public_key_sha256.clone(),
                next.credential_sha256.clone(),
                record
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(epoch)
    }
}
