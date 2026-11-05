// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One physical engine, exported by MRR Data. Weaver retains its domain schema.
//! Synchronous Gateway workers drive native futures with the standard executor;
//! there is no second runtime, database provider, ORM or SQLite fallback.
pub(crate) mod authority;
mod catalog;
pub(crate) mod owner;
pub(crate) mod scheduler;
pub(crate) use catalog::engine_metadata;
#[cfg(any(test, feature = "commit-observer"))]
pub mod commit_observer;
mod query;
mod scope;
mod scope_keys;
#[cfg(feature = "commit-observer")]
mod scope_trace;
#[cfg(feature = "commit-observer")]
pub use scope_trace::ProviderScopeSample;
mod session;
mod timing;
pub use mrr_data_backend::turso_driver::{self as driver, Error, Result, Row, params};
pub use owner::Journal;
#[cfg(feature = "commit-observer")]
pub use query::use_cached_currentness_plans;
pub use query::{exec, maybe, one, read_all, script};
pub(crate) use query::{maybe_current, one_current, read_all_current};
#[cfg(feature = "commit-observer")]
pub use scope::ProviderScopePhase;
#[cfg(not(feature = "commit-observer"))]
pub(crate) use scope::ProviderScopePhase;
pub use scope::{WriteScope, begin};
pub(crate) use scope::{begin_family, begin_provider_use};
pub use session::{LedgerCustody, Session};
pub use timing::{Timing, TransactionTimings};
