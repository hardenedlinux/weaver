// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed, fallible Rust-to-Scheme construction on the VM owner thread.
mod records;
mod values;
pub use records::root_source;
