// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Typed query transport through MRR Data's native `Turso` connection.
use super::driver::{Connection, Error, IntoParams, Result, Row};
use futures_executor::block_on;

/// Execute one parameter-bound statement on the caller's native connection.
pub fn exec(connection: &Connection, sql: &str, params: impl IntoParams) -> Result<u64> {
    block_on(connection.execute(sql, params))
}
/// Execute trusted schema or host-test SQL without opening another engine.
pub fn script(connection: &Connection, sql: &str) -> Result<()> {
    block_on(connection.execute_batch(sql))
}
/// Decode an optional first row; absence carries no admission authority.
pub fn maybe<T>(
    connection: &Connection,
    sql: &str,
    params: impl IntoParams,
    decode: impl FnOnce(&Row) -> Result<T>,
) -> Result<Option<T>> {
    block_on(async {
        let mut rows = connection.query(sql, params).await?;
        match rows.next().await? {
            Some(row) => decode(&row).map(Some),
            None => Ok(None),
        }
    })
}
/// Decode the required first row or return the native missing-row error.
pub fn one<T>(
    connection: &Connection,
    sql: &str,
    params: impl IntoParams,
    decode: impl FnOnce(&Row) -> Result<T>,
) -> Result<T> {
    maybe(connection, sql, params, decode)?.ok_or(Error::QueryReturnedNoRows)
}
/// Decode rows from a domain-bounded query on the existing transaction.
pub fn read_all<T>(
    connection: &Connection,
    sql: &str,
    params: impl IntoParams,
    mut decode: impl FnMut(&Row) -> Result<T>,
) -> Result<Vec<T>> {
    block_on(async {
        let mut rows = connection.query(sql, params).await?;
        let mut result = Vec::new();
        while let Some(row) = rows.next().await? {
            result.push(decode(&row)?);
        }
        Ok(result)
    })
}
