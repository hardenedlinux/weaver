// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Per-response pure projection; the existing ledger/output owner retains I/O.
mod encoder;
mod metadata;
mod observation;
pub use encoder::ProviderSseEncoder;

#[cfg(test)]
#[path = "../../../tests/unit/provider_projection.rs"]
mod tests;
