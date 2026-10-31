//! A request selects only an admitted name; original content stays catalog-owned.
use super::{CatalogError, ProducerCatalog};
use crate::{SourceClient, SourceJob};
use std::sync::Arc;
use weaver_contracts::SourceAuthority;
/// Cloneable finite producer client. Callers cannot replace entries or originals.
#[derive(Clone)]
pub struct ProducerClient {
    pub(super) catalog: Arc<ProducerCatalog>,
    pub(super) client: SourceClient,
}
impl ProducerClient {
    /// The service must derive this authority from authenticated identity and
    /// current source state, never request labels. It is an observation, not a
    /// reusable permit; current publication and final-use checks remain required.
    pub fn submit(
        &self,
        name: &str,
        observed: &SourceAuthority,
    ) -> Result<SourceJob, CatalogError> {
        let entry = self.catalog.entries.get(name).ok_or(CatalogError::Denied)?;
        if &entry.authority != observed {
            return Err(CatalogError::Denied);
        }
        // Immutable sharing keeps admission bounded without cloning/parsing every
        // body again. The lane independently retains this original before FFI.
        self.client
            .submit(entry.original.clone())
            .map_err(CatalogError::from)
    }
}
