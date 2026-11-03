// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Authoritative origins and shared budget/history domains.
mod binding;
mod evidence;
mod migration;
mod view;
pub(crate) use binding::bind;
pub(crate) use evidence::{charge, history, require};
pub(crate) use view::{lock_keys, require_stamp, stamp, view};
