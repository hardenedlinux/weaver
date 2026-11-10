// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Deployment runtime construction; the binary adapter retains process exit handling.

/// Run the deployment service with the default Tokio runtime and its normal drain.
#[tokio::main]
pub async fn run() -> weaver_contracts::Result<()> {
    run_on_runtime().await
}

/// Prepare the approved source over the separate authenticated source listener.
#[tokio::main(flavor = "current_thread")]
pub async fn prepare(config: Option<std::path::PathBuf>) -> weaver_contracts::Result<()> {
    tokio::time::timeout(
        std::time::Duration::from_secs(15),
        crate::source_prepare::run(config.as_deref()),
    )
    .await
    .map_err(|_| weaver_contracts::Error::Conflict("source preparation deadline"))?
}

/// Emit an inert reviewed catalog proposal using the existing wire record.
pub fn import_provider(
    source: &std::path::Path,
    yaml: bool,
    review: &std::path::Path,
) -> weaver_contracts::Result<()> {
    use std::io::Write;
    let record = crate::provider_import::proposal(source, yaml, review)?;
    let mut output = std::io::stdout().lock();
    output
        .write_all(&record)
        .and_then(|_| output.write_all(b"\n"))
        .map_err(|_| weaver_contracts::Error::Invalid("provider import output"))
}

/// Reconcile the deployment-bound Kubernetes resource through the source listener.
#[cfg(feature = "kubernetes")]
#[tokio::main(flavor = "current_thread")]
pub async fn reconcile_kubernetes(config: std::path::PathBuf) -> weaver_contracts::Result<()> {
    crate::kubernetes::run(&config).await
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
    crate::shutdown::trace("service-returned");
    let closed = storage
        .close()
        .map_err(|error| weaver_contracts::Error::Storage(error.to_string()));
    if closed.is_ok() {
        crate::shutdown::trace("storage-closed");
    }
    result.and(closed)
}
