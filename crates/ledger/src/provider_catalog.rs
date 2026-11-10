// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Read current provider catalogs and verify their published content.

use crate::{
    Ledger,
    persistence::{self, driver},
    store::{db, integer},
};
use weaver_contracts::{Error, MAX_CREDITS, ProviderCatalog, Result};

pub(crate) fn current(
    connection: &driver::Connection,
) -> Result<Option<(String, ProviderCatalog)>> {
    current_record(connection)?
        .map(|(digest, record)| {
            let catalog = decode(&digest, &record)?;
            Ok((digest, catalog))
        })
        .transpose()
}

#[cfg(test)]
#[path = "../tests/unit/provider_catalog.rs"]
mod tests;

fn current_record(connection: &driver::Connection) -> Result<Option<(String, String)>> {
    persistence::maybe(
        connection,
        "SELECT digest,record FROM provider_catalog_publications ORDER BY revision DESC LIMIT 1",
        (),
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .map_err(db)
}

pub(crate) fn historical(connection: &driver::Connection, digest: &str) -> Result<ProviderCatalog> {
    let record: String = persistence::one(
        connection,
        "SELECT record FROM provider_catalog_publications WHERE digest=?1",
        [digest],
        |row| row.get(0),
    )
    .map_err(db)?;
    decode(digest, &record)
}

fn decode(digest: &str, record: &str) -> Result<ProviderCatalog> {
    let catalog: ProviderCatalog = weaver_contracts::decode(record.as_bytes())?;
    if catalog.digest()? != digest {
        return Err(Error::Conflict("provider catalog content mismatch"));
    }
    Ok(catalog)
}

/// One source owner's verified wire projection. Current source authority and
/// current stored bytes must be read before it can be reused.
#[derive(Default)]
pub struct ProviderCatalogProjection {
    canonical: Option<(String, Vec<u8>)>,
}

impl ProviderCatalogProjection {
    fn project(&mut self, version: String, record: String) -> Result<(String, Vec<u8>)> {
        if self.canonical.as_ref().is_some_and(|(digest, bytes)| {
            *digest == version && bytes.as_slice() == record.as_bytes()
        }) {
            return Ok((version, record.into_bytes()));
        }
        let canonical = decode(&version, &record)?.record()?;
        self.canonical = (canonical.len() <= 262_144 && canonical == record.as_bytes())
            .then(|| (version.clone(), canonical.clone()));
        Ok((version, canonical))
    }
}

impl Ledger {
    pub fn provider_catalog(&self) -> Result<Option<(String, ProviderCatalog)>> {
        crate::source_authority::require(&self.connection, self.source.as_ref())?;
        current(&self.connection)
    }

    /// Read and verify the current catalog for the authenticated source RPC.
    pub fn inspect_provider_catalog(
        &self,
        projection: &mut ProviderCatalogProjection,
    ) -> Result<Option<(String, Vec<u8>)>> {
        crate::source_authority::require(&self.connection, self.source.as_ref())?;
        current_record(&self.connection)?
            .map(|(version, record)| projection.project(version, record))
            .transpose()
    }

    pub fn publish_provider_catalog(&mut self, catalog: &ProviderCatalog) -> Result<String> {
        let digest = catalog.digest()?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let deployment = crate::metering::deployment(&tx)?.ok_or(Error::Denied)?;
        catalog.validate(&deployment)?;
        let seen: bool = persistence::one(
            &tx,
            "SELECT EXISTS(SELECT 1 FROM provider_catalog_publications WHERE digest=?1)",
            [digest.as_str()],
            |row| row.get(0),
        )
        .map_err(db)?;
        if seen {
            if historical(&tx, &digest)? != *catalog {
                return Err(Error::Conflict("provider catalog replay changed"));
            }
            return Ok(digest);
        }
        let head: Option<(u64, String)> = persistence::maybe(&tx,
            "SELECT revision,digest FROM provider_catalog_publications ORDER BY revision DESC LIMIT 1",
            (), |row| Ok((integer(row, 0)?, row.get(1)?))).map_err(db)?;
        let (revision, parent) = head.unwrap_or_default();
        if catalog.parent != parent || revision == MAX_CREDITS {
            return Err(Error::Conflict("stale provider catalog parent"));
        }
        persistence::exec(
            &tx,
            "INSERT INTO provider_catalog_publications VALUES(?1,?2,?3)",
            persistence::params![
                (revision + 1) as i64,
                digest.clone(),
                serde_json::to_string(catalog)?
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(digest)
    }
}
