// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Install process signals before admission, then enter the ordinary tracked drain path.
use weaver_contracts::Result;

pub(crate) fn trace(stage: &str) {
    use std::io::{self, Write};
    use std::time::{SystemTime, UNIX_EPOCH};
    let wall = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    // The linked Scheme runtime also writes to stderr. Format before writing
    // so its diagnostics cannot land between this record's fields.
    let line = format!(
        "weaver shutdown stage={stage} wall_ns={}\n",
        wall.as_nanos()
    );
    let _ = io::stderr().lock().write_all(line.as_bytes());
}

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
