// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Recognize only the pinned engine's exact MVCC recovery metadata shape.
use super::{driver, one, read_all};

pub(crate) fn engine_metadata(
    connection: &driver::Connection,
    table: &str,
) -> driver::Result<bool> {
    if table != "__turso_internal_mvcc_meta" {
        return Ok(false);
    }
    let mode: String = one(connection, "PRAGMA journal_mode", (), |row| row.get(0))?;
    if mode != "mvcc" {
        return Ok(false);
    }
    let columns = read_all(
        connection,
        "PRAGMA main.table_info('__turso_internal_mvcc_meta')",
        (),
        |row| {
            Ok((
                row.get::<String>(1)?,
                row.get::<String>(2)?,
                row.get::<i64>(3)?,
            ))
        },
    )?;
    if columns
        != vec![
            ("k".into(), "TEXT".into(), 0),
            ("v".into(), "INTEGER".into(), 1),
        ]
    {
        return Ok(false);
    }
    one(
        connection,
        "SELECT COUNT(*)=1 AND COALESCE(SUM(CASE WHEN rowid=1 AND k='persistent_tx_ts_max' AND typeof(v)='integer' AND v>=0 THEN 1 ELSE 0 END),0)=1 FROM main.__turso_internal_mvcc_meta",
        (),
        |row| row.get(0),
    )
}
