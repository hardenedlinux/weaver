// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authoritative origins and shared budget/history domains.
mod binding;
mod evidence;
mod migration;
mod view;
pub(crate) use binding::bind;
pub(crate) use evidence::{charge, history, require, require_view};
#[cfg(feature = "commit-observer")]
pub use view::use_fresh_provider_domain_plan;
pub(crate) use view::{
    lock_keys, provider_view, require_stamp, stamp, stamp_keys, view, view_current,
    warm_provider_domain_plan,
};
