// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! External data configuration, not the Scheme/Rust interop representation.
use super::{ApprovedProducer, CatalogError, ProducerCatalog};
use crate::{MAX_SOURCE_BYTES, OwnedSource, SourceComposition, SourceData, SourceError};
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
    #[serde(default)]
    original: Option<SourceData>,
    #[serde(default)]
    composition: Option<SourceComposition>,
}
impl ProducerCatalog {
    /// Decode duplicate-free bounded startup data and reuse sealed catalog
    /// admission. Authority values are eligibility bindings, not authenticated
    /// observations, enrollment commands or permission to publish/send.
    pub fn from_configuration(bytes: &[u8]) -> Result<Self, CatalogError> {
        Self::from_configuration_with(bytes, |_| Err(SourceError::Contract))
    }
    /// Compose trusted startup configuration on the already tracked Scheme owner,
    /// then reuse the unchanged exact-original catalog and source lane.
    pub fn from_configuration_with(
        bytes: &[u8],
        mut compose: impl FnMut(&SourceComposition) -> Result<OwnedSource, SourceError>,
    ) -> Result<Self, CatalogError> {
        if bytes.len() > MAX_SOURCE_BYTES {
            return Err(CatalogError::Invalid);
        }
        let input: Configuration =
            weaver_contracts::decode(bytes).map_err(|_| CatalogError::Invalid)?;
        if input.producers.is_empty() || input.producers.len() > 64 {
            return Err(CatalogError::Invalid);
        }
        let entries = input
            .producers
            .into_iter()
            .map(|entry| {
                let original = match (entry.original, entry.composition) {
                    (Some(data), None) => OwnedSource::from_source(data),
                    (None, Some(configuration)) => compose(&configuration).and_then(|selected| {
                        configuration.validate_selected(&selected)?;
                        Ok(selected)
                    }),
                    _ => return Err(CatalogError::Invalid),
                }
                .map_err(|_| CatalogError::Invalid)?;
                ApprovedProducer::new(entry.name, entry.authority, original)
            })
            .collect::<Result<Vec<_>, CatalogError>>()?;
        Self::from_entries(entries)
    }
}
