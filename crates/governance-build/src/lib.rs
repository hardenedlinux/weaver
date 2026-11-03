// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Compiler-owned governance graph assembly for Cargo; no runtime execution API.
mod application;
mod program;
mod stage;
mod tooling;
pub use application::ProgramApplication;
pub use program::build_program;
pub use stage::{ProgramStageRequest, RUNTIME_IMPORTS};
#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());
#[cfg(test)]
#[path = "../tests/unit/paths.rs"]
mod path_tests;

pub use tooling::{PackageTooling, stage_program};
