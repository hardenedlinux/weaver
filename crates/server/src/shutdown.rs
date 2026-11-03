// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Install process signals before admission, then enter the ordinary tracked drain path.
use weaver_contracts::Result;

#[cfg(unix)]
pub(crate) fn signal() -> Result<impl std::future::Future<Output = ()> + Send> {
    use tokio::signal::unix::{SignalKind, signal};
    use weaver_contracts::Error;
    let mut interrupt =
        signal(SignalKind::interrupt()).map_err(|e| Error::Storage(e.to_string()))?;
    let mut terminate =
        signal(SignalKind::terminate()).map_err(|e| Error::Storage(e.to_string()))?;
    Ok(async move {
        tokio::select! {
            _ = interrupt.recv() => {},
            _ = terminate.recv() => {},
        }
    })
}

#[cfg(not(unix))]
pub(crate) fn signal() -> Result<impl std::future::Future<Output = ()> + Send> {
    Ok(async {
        let _ = tokio::signal::ctrl_c().await;
    })
}
