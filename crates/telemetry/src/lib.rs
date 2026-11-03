// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Bounded local telemetry with no execution, storage or transport capability.
#![forbid(unsafe_code)]
mod metrics;
pub use metrics::{Metrics, Signal, Snapshot};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
