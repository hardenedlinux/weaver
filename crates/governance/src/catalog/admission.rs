// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bound each original to one fixed producer name and source-authority observation.
use super::{client::ProducerClient, text_size::text_bytes};
use crate::{MAX_SOURCE_BYTES, OwnedSource, SourceClient, SourceJobError};
use std::{collections::BTreeMap, sync::Arc};
use weaver_contracts::{SourceAuthority, identifier};

/// A local selection error conveys no original source content or live permit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum CatalogError {
    #[error("producer catalog bound or conflicting original")]
    Invalid,
    #[error("producer selection or source-authority binding rejected")]
    Denied,
    #[error("producer owner unavailable: {0}")]
    Schedule(#[from] SourceJobError),
}
/// Constructed by the trusted embedding from independently admitted original data.
/// Neither a hash-shaped string nor this constructor proves key possession.
pub struct ApprovedProducer {
    pub(super) name: String,
    pub(super) authority: SourceAuthority,
    pub(super) original: OwnedSource,
}
impl ApprovedProducer {
    /// Freeze a concrete producer binding; a request cannot supply another source.
    pub fn new(
        name: String,
        authority: SourceAuthority,
        original: OwnedSource,
    ) -> Result<Self, CatalogError> {
        identifier(&name).map_err(|_| CatalogError::Invalid)?;
        authority
            .identity
            .validate()
            .map_err(|_| CatalogError::Invalid)?;
        if authority.epoch > weaver_contracts::MAX_CREDITS {
            return Err(CatalogError::Invalid);
        }
        Ok(Self {
            name,
            authority,
            original,
        })
    }
}
/// Finite immutable invocation catalog, distinct from the authoritative source ledger.
/// Reconstructing it cannot reset an original claim, reservation or source outcome.
pub struct ProducerCatalog {
    pub(super) entries: BTreeMap<String, ApprovedProducer>,
}
impl ProducerCatalog {
    /// Refuse aliases for one original family and conflicting publication IDs.
    /// Total copied text is bounded separately from native constructor traversal.
    pub fn from_entries(entries: Vec<ApprovedProducer>) -> Result<Self, CatalogError> {
        if entries.is_empty() || entries.len() > 64 {
            return Err(CatalogError::Invalid);
        }
        let mut catalog = BTreeMap::new();
        let mut families = std::collections::BTreeSet::new();
        let mut publications = BTreeMap::new();
        let mut remaining = MAX_SOURCE_BYTES;
        for entry in entries {
            remaining = remaining
                .checked_sub(text_bytes(entry.original.data()).ok_or(CatalogError::Invalid)?)
                .ok_or(CatalogError::Invalid)?;
            remaining = remaining
                .checked_sub(entry.name.len())
                .ok_or(CatalogError::Invalid)?;
            if !families.insert(entry.original.task().family.clone()) {
                return Err(CatalogError::Invalid);
            }
            let publication = entry.original.publication();
            if let Some(prior) =
                publications.insert(publication.operation_id.clone(), publication.clone())
                && prior != *publication
            {
                return Err(CatalogError::Invalid);
            }
            if catalog.insert(entry.name.clone(), entry).is_some() {
                return Err(CatalogError::Invalid);
            }
        }
        Ok(Self { entries: catalog })
    }
    /// Bind the sealed set to a trusted, already approved compiler owner. This
    /// does not authenticate that compiler or install a live source authority.
    pub fn bind(self, client: SourceClient) -> ProducerClient {
        ProducerClient {
            catalog: Arc::new(self),
            client,
        }
    }
}
