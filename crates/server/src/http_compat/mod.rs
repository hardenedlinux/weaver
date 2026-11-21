// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Thin operation-only HTTP compatibility on the existing runtime and source lane.
mod config;
mod request;
mod service;
pub use config::HttpProfile;
pub(crate) use config::load;
pub(crate) use service::serve;
