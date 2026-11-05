// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Immutable trusted-host producer selection; no durable authority or execution grant.
mod admission;
mod client;
mod configuration;
mod text_size;
pub use admission::{ApprovedProducer, CatalogError, ProducerCatalog};
pub use client::ProducerClient;
