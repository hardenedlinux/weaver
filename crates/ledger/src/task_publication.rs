//! Original staged task admission waits for its exact committed publication.
use crate::{publication, store::db};
use rusqlite::{Connection, OptionalExtension, params};
use weaver_contracts::{Error, PublicationKey, PublicationOutcome, Result};

fn binding(connection: &Connection, family: &str) -> Result<Option<PublicationKey>> {
    connection
        .query_row(
            "SELECT operation_id,digest FROM task_publications WHERE family=?1",
            [family],
            |row| {
                Ok(PublicationKey {
                    operation_id: row.get(0)?,
                    digest: row.get(1)?,
                })
            },
        )
        .optional()
        .map_err(db)
}

fn committed(connection: &Connection, key: &PublicationKey) -> Result<()> {
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
    connection: &Connection,
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
    connection
        .execute(
            "INSERT INTO task_publications VALUES(?1,?2,?3)",
            params![family, key.operation_id, key.digest],
        )
        .map_err(db)?;
    Ok(())
}

pub(crate) fn require(connection: &Connection, family: &str) -> Result<()> {
    if let Some(original) = binding(connection, family)? {
        committed(connection, &original)?;
    }
    Ok(())
}
