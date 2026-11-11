// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source command admission and the affine ledger worker.
mod command;
mod handle;
mod worker;

pub(crate) use handle::{OperationResolver, SourceOwner};
