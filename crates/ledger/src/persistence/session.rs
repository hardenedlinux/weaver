//! One verified durable `Turso` session owned by the Gateway host.
use super::{driver, one, script};
use std::{
    ops::Deref,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

/// One FULL/WAL Turso connection. There is no automatic engine/store conversion.
pub struct Session {
    pub(super) connection: driver::Connection,
    pub(super) owner: Arc<super::owner::Owner>,
    pub(super) poisoned: AtomicBool,
}
impl Session {
    /// Open through MRR Data and read back the required durability settings.
    pub fn open(path: impl AsRef<Path>) -> driver::Result<Self> {
        Self::connect(path.as_ref(), None)
    }
    /// Select MVCC explicitly; default opens join this live owner's profile.
    pub fn open_with_journal(
        path: impl AsRef<Path>,
        journal: super::Journal,
    ) -> driver::Result<Self> {
        Self::connect(path.as_ref(), Some(journal))
    }
    fn connect(path: &Path, requested: Option<super::Journal>) -> driver::Result<Self> {
        let owner = super::owner::open(path, requested)?;
        let connection = owner.database.connect()?;
        connection.busy_timeout(Duration::from_secs(10))?;
        script(
            &connection,
            "PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
        )?;
        let mode: String = one(&connection, "PRAGMA journal_mode", (), |r| r.get(0))?;
        let synchronous: i64 = one(&connection, "PRAGMA synchronous", (), |r| r.get(0))?;
        let foreign_keys: i64 = one(&connection, "PRAGMA foreign_keys", (), |r| r.get(0))?;
        let expected = match owner.journal {
            super::Journal::Wal => "wal",
            super::Journal::Mvcc => "mvcc",
        };
        if mode != expected || synchronous != 2 || foreign_keys != 1 {
            return Err(driver::Error::Misuse(
                "required WAL/FULL/foreign-key storage profile unavailable".into(),
            ));
        }
        Ok(Self {
            connection,
            owner,
            poisoned: AtomicBool::new(false),
        })
    }
    /// Initialize this live MVCC owner's ledger once; this never caches authorization.
    pub(crate) fn initialize_ledger(&mut self) -> driver::Result<()> {
        self.require_quiescent()?;
        let owner = self.owner.clone();
        let mvcc = owner.journal == super::Journal::Mvcc;
        if mvcc && owner.ledger_initialized.load(Ordering::Acquire) {
            return Ok(());
        }
        let transaction = super::begin(self)?;
        if !mvcc || !owner.ledger_initialized.load(Ordering::Acquire) {
            script(&transaction, crate::schema::SCHEMA)?;
        }
        transaction.commit()?;
        owner.ledger_initialized.store(true, Ordering::Release);
        Ok(())
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
