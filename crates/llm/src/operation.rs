// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Prepared operation transport identity, without a dependency on Server or gRPC.

use crate::{
    Error,
    files::{SecretReference, read_bounded},
    oauth::OAuthSession,
};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct OperationSettings {
    server_name: String,
    ca: PathBuf,
    certificate: PathBuf,
    key: PathBuf,
    pub credential: SecretReference,
}

pub(crate) struct OperationMaterial {
    pub server_name: String,
    pub ca: Zeroizing<Vec<u8>>,
    pub certificate: Zeroizing<Vec<u8>>,
    pub key: Zeroizing<Vec<u8>>,
    pub bearer: reqwest::header::HeaderValue,
    pub binding: String,
}

impl OperationSettings {
    pub async fn prepare(&self, directory: &Path) -> Result<OperationMaterial, Error> {
        if self.server_name.trim().is_empty() {
            return Err(Error::Configuration);
        }
        let ca_path = directory.join(&self.ca);
        let certificate_path = directory.join(&self.certificate);
        let key_path = directory.join(&self.key);
        let (ca, certificate, key) = tokio::try_join!(
            read_bounded(&ca_path, 64 * 1024, false),
            read_bounded(&certificate_path, 64 * 1024, false),
            read_bounded(&key_path, 64 * 1024, true),
        )?;
        let secret = self.credential.resolve(directory).await?;
        let mut bearer =
            reqwest::header::HeaderValue::from_str(&format!("Bearer {}", secret.as_str()))
                .map_err(|_| Error::Configuration)?;
        bearer.set_sensitive(true);
        use sha2::{Digest, Sha256};
        let mut digest = Sha256::new();
        for bytes in [
            self.server_name.as_bytes(),
            ca.as_slice(),
            certificate.as_slice(),
            key.as_slice(),
            secret.as_bytes(),
        ] {
            digest.update((bytes.len() as u64).to_le_bytes());
            digest.update(bytes);
        }
        Ok(OperationMaterial {
            server_name: self.server_name.clone(),
            ca,
            certificate,
            key,
            bearer,
            binding: format!("{:x}", digest.finalize()),
        })
    }
}

/// Immutable operation TLS/bearer material and its separately prepared OIDC owner.
/// Transport adapters consume these values without reading the configuration again.
pub struct PreparedOperation {
    /// Canonical operation resource URI.
    pub endpoint: String,
    /// Expected TLS server identity.
    pub server_name: String,
    /// Explicit server trust root.
    pub ca: Zeroizing<Vec<u8>>,
    /// Operation client certificate.
    pub certificate: Zeroizing<Vec<u8>>,
    /// Private operation key; never a source/publication identity.
    pub key: Zeroizing<Vec<u8>>,
    /// Sensitive operation bearer, independent of the exchanged credential.
    pub operation_bearer: reqwest::header::HeaderValue,
    /// Shared browser login and delegated exchange owner.
    pub identity: OAuthSession,
}

impl std::fmt::Debug for PreparedOperation {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PreparedOperation").finish_non_exhaustive()
    }
}
