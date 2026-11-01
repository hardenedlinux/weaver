//! One verified durable `Turso` session owned by the Gateway host.
use super::{driver, one, script};
use futures_executor::block_on;
use std::{
    ops::Deref,
    path::Path,
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

/// One FULL/WAL Turso connection. There is no automatic engine/store conversion.
pub struct Session {
    pub(super) connection: driver::Connection,
    _database: driver::Database,
    pub(super) poisoned: AtomicBool,
}
impl Session {
    /// Open through MRR Data and read back the required durability settings.
    pub fn open(path: impl AsRef<Path>) -> driver::Result<Self> {
        let path = path
            .as_ref()
            .to_str()
            .filter(|p| !p.is_empty() && *p != ":memory:")
            .ok_or_else(|| driver::Error::Misuse("durable storage path required".into()))?;
        let database = block_on(
            driver::Builder::new_local(path)
                .experimental_multiprocess_wal(true)
                .build(),
        )?;
        let connection = database.connect()?;
        connection.busy_timeout(Duration::from_secs(10))?;
        script(
            &connection,
            "PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
        )?;
        let mode: String = one(&connection, "PRAGMA journal_mode", (), |r| r.get(0))?;
        let synchronous: i64 = one(&connection, "PRAGMA synchronous", (), |r| r.get(0))?;
        let foreign_keys: i64 = one(&connection, "PRAGMA foreign_keys", (), |r| r.get(0))?;
        if mode != "wal" || synchronous != 2 || foreign_keys != 1 {
            return Err(driver::Error::Misuse(
                "required WAL/FULL/foreign-key storage profile unavailable".into(),
            ));
        }
        Ok(Self {
            connection,
            _database: database,
            poisoned: AtomicBool::new(false),
        })
    }
    /// Refuse reuse after an unresolved or failed transaction.
    pub fn require_quiescent(&self) -> driver::Result<()> {
        if self.poisoned.load(Ordering::Acquire) || !self.connection.is_autocommit()? {
            return Err(driver::Error::Misuse(
                "unresolved storage transaction".into(),
            ));
        }
        Ok(())
    }
    /// Report clean completion only when no transaction remains unresolved.
    pub fn close(self) -> driver::Result<()> {
        self.require_quiescent()
    }
}
impl Deref for Session {
    type Target = driver::Connection;
    fn deref(&self) -> &Self::Target {
        &self.connection
    }
}
