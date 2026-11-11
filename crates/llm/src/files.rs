// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded file input shared by trusted configuration and credential stores.

use crate::Error;
use std::path::Path;
use tokio::io::AsyncReadExt;
use zeroize::Zeroizing;

pub(crate) const SECRET_LIMIT: u64 = 16 * 1024;

#[derive(Clone, serde::Deserialize)]
#[serde(untagged, deny_unknown_fields)]
pub(crate) enum SecretReference {
    Environment { env: String },
    File { file: std::path::PathBuf },
}

impl SecretReference {
    pub fn environment(&self) -> Option<&str> {
        match self {
            Self::Environment { env } => Some(env),
            Self::File { .. } => None,
        }
    }

    pub async fn resolve(&self, directory: &Path) -> Result<Zeroizing<String>, Error> {
        let secret = match self {
            Self::Environment { env } => {
                Zeroizing::new(std::env::var(env).map_err(|_| Error::Configuration)?)
            }
            Self::File { file } => {
                let bytes = read_bounded(&directory.join(file), SECRET_LIMIT, true).await?;
                let text = std::str::from_utf8(&bytes).map_err(|_| Error::Configuration)?;
                Zeroizing::new(text.trim_end_matches(['\r', '\n']).to_owned())
            }
        };
        if secret.is_empty() || secret.len() as u64 > SECRET_LIMIT || secret.trim() != *secret {
            return Err(Error::Configuration);
        }
        Ok(secret)
    }
}

pub(crate) async fn read_bounded(
    path: &Path,
    limit: u64,
    private: bool,
) -> Result<Zeroizing<Vec<u8>>, Error> {
    let metadata = tokio::fs::metadata(path)
        .await
        .map_err(|_| Error::Configuration)?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err(Error::Configuration);
    }
    let file = tokio::fs::File::open(path)
        .await
        .map_err(|_| Error::Configuration)?;
    let metadata = file.metadata().await.map_err(|_| Error::Configuration)?;
    if !metadata.is_file() {
        return Err(Error::Configuration);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if private && metadata.permissions().mode() & 0o077 != 0 {
            return Err(Error::Configuration);
        }
    }
    #[cfg(not(unix))]
    let _ = private;
    let mut bytes = Zeroizing::new(Vec::new());
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| Error::Configuration)?;
    if bytes.len() as u64 > limit {
        return Err(Error::Configuration);
    }
    Ok(bytes)
}
