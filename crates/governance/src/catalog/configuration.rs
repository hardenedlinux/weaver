// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! External data configuration, not the Scheme/Rust interop representation.
use super::{ApprovedProducer, CatalogError, ProducerCatalog};
use crate::{OwnedSource, SourceData};
use serde::Deserialize;
use weaver_contracts::SourceAuthority;
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    producers: Vec<Binding>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    name: String,
    authority: SourceAuthority,
    original: SourceData,
}
impl ProducerCatalog {
    /// Decode duplicate-free bounded startup data and reuse sealed catalog
    /// admission. Authority values are eligibility bindings, not authenticated
    /// observations, enrollment commands or permission to publish/send.
    pub fn from_configuration(bytes: &[u8]) -> Result<Self, CatalogError> {
        let input: Configuration =
            weaver_contracts::decode(bytes).map_err(|_| CatalogError::Invalid)?;
        if input.producers.is_empty() || input.producers.len() > 64 {
            return Err(CatalogError::Invalid);
        }
        let entries = input
            .producers
            .into_iter()
            .map(|entry| {
                let original =
                    OwnedSource::from_source(entry.original).map_err(|_| CatalogError::Invalid)?;
                ApprovedProducer::new(entry.name, entry.authority, original)
            })
            .collect::<Result<Vec<_>, CatalogError>>()?;
        Self::from_entries(entries)
    }
}
