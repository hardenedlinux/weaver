// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Local Scheme-to-Rust Policy preflight. Success never grants execution rights.
//! No callbacks, allocations returned to C, owner handles, or ledger mutations.
#[allow(unsafe_code)]
mod abi;
pub use abi::{weaver_policy_abi_v1, weaver_policy_validate_v1};

mod validation;
pub use validation::{MAX_SOURCE_BYTES, validate};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());

#[cfg(test)]
#[path = "../tests/unit/validation.rs"]
mod validation_tests;
