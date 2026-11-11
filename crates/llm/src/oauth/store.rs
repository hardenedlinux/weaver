// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{Error, files::read_bounded};
use std::{
    path::{Path, PathBuf},
    sync::Arc,
};
use tokio::io::AsyncWriteExt;
use zeroize::Zeroizing;

pub(super) struct TokenStore {
    path: PathBuf,
    lease: Arc<std::fs::File>,
    writes: Arc<tokio::sync::Mutex<()>>,
    tasks: tokio_util::task::TaskTracker,
}

impl TokenStore {
    pub(super) async fn open(path: &Path) -> Result<Self, Error> {
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or(Error::Configuration)?;
        let mut builder = tokio::fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        builder.mode(0o700);
        builder
            .create(parent)
            .await
            .map_err(|_| Error::Configuration)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let metadata = tokio::fs::metadata(parent)
                .await
                .map_err(|_| Error::Configuration)?;
            if metadata.permissions().mode() & 0o077 != 0 {
                return Err(Error::Configuration);
            }
        }
        let mut name = path.file_name().ok_or(Error::Configuration)?.to_os_string();
        name.push(".lock");
        let mut options = tokio::fs::OpenOptions::new();
        options.create(true).truncate(false).read(true).write(true);
        #[cfg(unix)]
        options.mode(0o600);
        // This is a nonblocking kernel lock, held across all async store operations.
        let lease = options
            .open(parent.join(name))
            .await
            .map_err(|_| Error::Configuration)?
            .into_std()
            .await;
        lease.try_lock().map_err(|_| Error::Configuration)?;
        Ok(Self {
            path: path.to_owned(),
            lease: Arc::new(lease),
            writes: Arc::new(tokio::sync::Mutex::new(())),
            tasks: tokio_util::task::TaskTracker::new(),
        })
    }

    pub(super) async fn load<T: serde::de::DeserializeOwned>(&self) -> Result<Option<T>, Error> {
        if !tokio::fs::try_exists(&self.path)
            .await
            .map_err(|_| Error::Configuration)?
        {
            return Ok(None);
        }
        let bytes = read_bounded(&self.path, 64 * 1024, true).await?;
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| Error::Configuration)
    }

    pub(super) async fn save<T: serde::Serialize>(&self, record: &T) -> Result<(), Error> {
        let bytes = Zeroizing::new(serde_json::to_vec(record).map_err(|_| Error::Authentication)?);
        if bytes.len() > 64 * 1024 {
            return Err(Error::Authentication);
        }
        // Acquire before spawning so cancellation cannot reorder durable writes.
        let guard = self.writes.clone().lock_owned().await;
        if self.tasks.is_closed() {
            return Err(Error::Authentication);
        }
        let lease = self.lease.clone();
        let path = self.path.clone();
        self.tasks
            .spawn(async move {
                let _guard = guard;
                let _lease = lease;
                Self::write_record(&path, bytes).await
            })
            .await
            .map_err(|_| Error::Authentication)?
    }

    pub(super) fn is_closed(&self) -> bool {
        self.tasks.is_closed()
    }

    pub(super) async fn shutdown(&self) {
        let guard = self.writes.lock().await;
        self.tasks.close();
        drop(guard);
        self.tasks.wait().await;
    }

    async fn write_record(path: &Path, bytes: Zeroizing<Vec<u8>>) -> Result<(), Error> {
        let name = format!(".weaver-oauth-{}", oauth2::CsrfToken::new_random().secret());
        let parent = path.parent().ok_or(Error::Configuration)?;
        let temporary = parent.join(name);
        let mut options = tokio::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        options.mode(0o600);
        let mut file = options
            .open(&temporary)
            .await
            .map_err(|_| Error::Authentication)?;
        file.write_all(&bytes)
            .await
            .map_err(|_| Error::Authentication)?;
        file.sync_all().await.map_err(|_| Error::Authentication)?;
        drop(file);
        tokio::fs::rename(&temporary, path)
            .await
            .map_err(|_| Error::Authentication)?;
        #[cfg(unix)]
        tokio::fs::File::open(parent)
            .await
            .map_err(|_| Error::Authentication)?
            .sync_all()
            .await
            .map_err(|_| Error::Authentication)?;
        Ok(())
    }
}
