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
    crate::persistence::maybe(
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
