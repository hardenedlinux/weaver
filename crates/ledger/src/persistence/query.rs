// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

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
    decode: impl FnMut(&Row) -> Result<T>,
) -> Result<Vec<T>> {
    block_on(async { decode_all(connection.query(sql, params).await?, decode).await })
}

#[cfg(feature = "commit-observer")]
thread_local! {
    static CACHE_CURRENTNESS_PLANS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Diagnostic control for the observed server only.
#[cfg(feature = "commit-observer")]
pub fn use_cached_currentness_plans(cached: bool) {
    CACHE_CURRENTNESS_PLANS.set(cached);
}

async fn currentness_rows(
    connection: &Connection,
    sql: &'static str,
    params: impl IntoParams,
) -> Result<super::driver::Rows> {
    #[cfg(feature = "commit-observer")]
    if CACHE_CURRENTNESS_PLANS.get() {
        // Diagnostic comparison only. Each cursor still uses the live
        // connection and current transaction, with fresh parameters.
        return connection.prepare_cached(sql).await?.query(params).await;
    }
    connection.query(sql, params).await
}

pub(crate) fn maybe_current<T>(
    connection: &Connection,
    sql: &'static str,
    params: impl IntoParams,
    decode: impl FnOnce(&Row) -> Result<T>,
) -> Result<Option<T>> {
    block_on(async {
        let mut rows = currentness_rows(connection, sql, params).await?;
        rows.next().await?.as_ref().map(decode).transpose()
    })
}

pub(crate) fn one_current<T>(
    connection: &Connection,
    sql: &'static str,
    params: impl IntoParams,
    decode: impl FnOnce(&Row) -> Result<T>,
) -> Result<T> {
    maybe_current(connection, sql, params, decode)?.ok_or(Error::QueryReturnedNoRows)
}

pub(crate) fn read_all_current<T>(
    connection: &Connection,
    sql: &'static str,
    params: impl IntoParams,
    decode: impl FnMut(&Row) -> Result<T>,
) -> Result<Vec<T>> {
    block_on(async { decode_all(currentness_rows(connection, sql, params).await?, decode).await })
}

pub(crate) fn read_all_manifest<T>(
    tx: &super::WriteScope<'_>,
    sql: &'static str,
    family: &str,
    prepared: bool,
    projected: bool,
    decode: impl FnMut(&Row) -> Result<T>,
) -> Result<Vec<T>> {
    let read = async {
        let rows = if prepared {
            tx.prepare_cached(sql).await?.query([family]).await?
        } else {
            currentness_rows(tx, sql, [family]).await?
        };
        decode_all(rows, decode).await
    };
    #[cfg(feature = "commit-observer")]
    {
        tx.observe_manifest_driver(projected, read)
    }
    #[cfg(not(feature = "commit-observer"))]
    {
        let _ = projected;
        block_on(read)
    }
}

/// Execute a fixed query returning at most one row. Reach Done before dropping
/// its cursor so the engine can finish the read instead of aborting it.
pub(crate) fn maybe_prepared<T>(
    connection: &Connection,
    sql: &'static str,
    params: impl IntoParams,
    decode: impl FnOnce(&Row) -> Result<T>,
) -> Result<Option<T>> {
    block_on(async {
        let mut statement = connection.prepare_cached(sql).await?;
        let mut rows = statement.query(params).await?;
        let Some(row) = rows.next().await? else {
            return Ok(None);
        };
        let value = decode(&row)?;
        if rows.next().await?.is_some() {
            return Err(Error::Misuse(
                "prepared singleton query returned multiple rows".into(),
            ));
        }
        Ok(Some(value))
    })
}

async fn decode_all<T>(
    mut rows: super::driver::Rows,
    mut decode: impl FnMut(&Row) -> Result<T>,
) -> Result<Vec<T>> {
    let mut result = Vec::new();
    while let Some(row) = rows.next().await? {
        result.push(decode(&row)?);
    }
    Ok(result)
}
