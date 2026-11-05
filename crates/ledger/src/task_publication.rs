// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Original staged task admission waits for its exact committed publication.
use crate::{publication, store::db};
use weaver_contracts::{Error, PublicationKey, PublicationOutcome, Result};

pub(crate) fn binding(
    connection: &crate::persistence::driver::Connection,
    family: &str,
) -> Result<Option<PublicationKey>> {
    crate::persistence::maybe_current(
        connection,
        "SELECT operation_id,digest FROM task_publications WHERE family=?1",
        crate::persistence::params![(family).to_owned()],
        |row| {
            Ok(PublicationKey {
                operation_id: row.get(0)?,
                digest: row.get(1)?,
            })
        },
    )
    .map_err(db)
}

fn committed(
    connection: &crate::persistence::driver::Connection,
    key: &PublicationKey,
) -> Result<()> {
    if publication::lookup(connection, &key.operation_id, &key.digest)?
        .is_some_and(|r| r.outcome == PublicationOutcome::Committed)
    {
        return Ok(());
    }
    Err(Error::Conflict(
        "original task publication is not committed",
    ))
}

pub(crate) fn bind(
    connection: &crate::persistence::driver::Connection,
    family: &str,
    key: Option<&PublicationKey>,
) -> Result<()> {
    let Some(key) = key else { return Ok(()) };
    key.validate()?;
    if let Some(original) = binding(connection, family)? {
        if original != *key {
            committed(connection, &original)?;
        }
        // Re-registering an existing committed original never replaces its birth.
        return Ok(());
    }
    crate::persistence::exec(
        connection,
        "INSERT INTO task_publications VALUES(?1,?2,?3)",
        crate::persistence::params![
            (family).to_owned(),
            (key.operation_id).to_owned(),
            (key.digest).to_owned()
        ],
    )
    .map_err(db)?;
    Ok(())
}

pub(crate) fn require(
    connection: &crate::persistence::driver::Connection,
    family: &str,
) -> Result<()> {
    if let Some(original) = binding(connection, family)? {
        committed(connection, &original)?;
    }
    Ok(())
}

/// A verified birth receipt whose exact bytes remain binding at use.
pub(crate) struct Prepared(Option<(PublicationKey, String)>);

pub(crate) fn prepare(
    c: &crate::persistence::driver::Connection,
    family: &str,
) -> Result<Prepared> {
    let Some(key) = binding(c, family)? else {
        return Ok(Prepared(None));
    };
    let row = publication::receipt_record(c, &key.operation_id)?;
    let bytes = row.as_ref().map(|(_, bytes)| bytes.clone());
    if !publication::decode_receipt(&key.operation_id, &key.digest, row)?
        .is_some_and(|r| r.outcome == PublicationOutcome::Committed)
    {
        return Err(Error::Conflict(
            "original task publication is not committed",
        ));
    }
    Ok(Prepared(Some((key, bytes.ok_or(Error::Denied)?))))
}

impl Prepared {
    pub(crate) fn require_current(
        &self,
        tx: &crate::persistence::WriteScope<'_>,
        family: &str,
    ) -> Result<()> {
        if binding(tx, family)?.as_ref() != self.0.as_ref().map(|(key, _)| key) {
            return Err(Error::Conflict("original task publication changed"));
        }
        if let Some((key, bytes)) = &self.0 {
            let matches: bool = crate::persistence::one_current(tx,
                "SELECT EXISTS(SELECT 1 FROM authority_publications WHERE operation_id=?1 AND digest=?2 AND receipt=?3)",
                [key.operation_id.as_str(), key.digest.as_str(), bytes.as_str()], |r| r.get(0)).map_err(db)?;
            if !matches {
                return Err(Error::Conflict("original task publication receipt changed"));
            }
        }
        Ok(())
    }
}
