//! One physical engine, exported by MRR Data. Weaver retains its domain schema.
//! Synchronous Gateway workers drive native futures with the standard executor;
//! there is no second runtime, database provider, ORM or SQLite fallback.
mod catalog;
mod owner;
pub(crate) use catalog::engine_metadata;
#[cfg(any(test, feature = "commit-observer"))]
pub mod commit_observer;
mod query;
mod scope;
mod session;
mod timing;
pub use mrr_data_backend::turso_driver::{self as driver, Error, Result, Row, params};
pub use owner::Journal;
pub use query::{exec, maybe, one, read_all, script};
pub(crate) use scope::begin_family;
pub use scope::{WriteScope, begin};
pub use session::Session;
pub use timing::{Timing, TransactionTimings};
