//! Immutable trusted-host producer selection; no durable authority or execution grant.
mod admission;
mod client;
mod configuration;
mod text_size;
pub use admission::{ApprovedProducer, CatalogError, ProducerCatalog};
pub use client::ProducerClient;
