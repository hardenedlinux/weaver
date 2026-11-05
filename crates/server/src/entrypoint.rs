// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Deployment runtime construction; the binary adapter retains process exit handling.

/// Run the deployment service with the default Tokio runtime and its normal drain.
#[tokio::main]
pub async fn run() -> weaver_contracts::Result<()> {
    run_on_runtime().await
}

pub(crate) async fn run_on_runtime() -> weaver_contracts::Result<()> {
    use weaver_ledger::{Journal, LedgerCustody};
    let journal = match std::env::var("WEAVER_STORAGE_JOURNAL").as_deref() {
        Ok("mvcc") => Journal::Mvcc,
        Ok("wal") | Err(std::env::VarError::NotPresent) => Journal::Wal,
        _ => return Err(weaver_contracts::Error::Invalid("storage journal")),
    };
    let path =
        std::env::var("WEAVER_DB").map_err(|_| weaver_contracts::Error::Invalid("storage path"))?;
    // Retain one native Database and process custody through complete service drain.
    let storage = LedgerCustody::open_with_journal(path, journal)
        .map_err(|error| weaver_contracts::Error::Storage(error.to_string()))?;
    let result = crate::run_from_env().await;
    let closed = storage
        .close()
        .map_err(|error| weaver_contracts::Error::Storage(error.to_string()));
    result.and(closed)
}
