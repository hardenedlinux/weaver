// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bounded source compilation on the caller's tracked blocking owner.
mod client;
mod owner;
mod request;
mod state;
pub use client::{SourceClient, source_lane};
pub use owner::SourceInbox;
pub(crate) use owner::governor_timing;
pub use request::{SourceJob, SourceJobError};
use state::{Command, Phase, Reply, Shared, State, Work};
pub use state::{Derivation, DerivationOutput, GovernorCut, GovernorTopology};
