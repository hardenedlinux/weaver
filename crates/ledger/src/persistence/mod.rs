//! One physical engine, exported by MRR Data. Weaver retains its domain schema.
//! Synchronous Gateway workers drive native futures with the standard executor;
//! there is no second runtime, database provider, ORM or SQLite fallback.
mod query;
mod scope;
mod session;
pub use mrr_data_backend::turso_driver::{self as driver, Error, Result, Row, params};
pub use query::{exec, maybe, one, read_all, script};
pub use scope::{WriteScope, begin};
pub use session::Session;
