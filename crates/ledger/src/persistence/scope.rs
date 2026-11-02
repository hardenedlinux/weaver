//! Explicit commit and eager rollback of one native `Turso` write transaction.
use super::{Session, driver};
use futures_executor::block_on;
use std::{
    ops::Deref,
    sync::atomic::{AtomicBool, Ordering},
    sync::{MutexGuard, RwLockReadGuard, RwLockWriteGuard},
};

/// Exclusive native transaction; final guarded callbacks keep this scope alive.
pub struct WriteScope<'a> {
    connection: &'a driver::Connection,
    native: Option<driver::transaction::Transaction<'a>>,
    poisoned: &'a AtomicBool,
    _exclusive: Option<RwLockWriteGuard<'a, ()>>,
    _shared: Option<RwLockReadGuard<'a, ()>>,
    _family: Option<MutexGuard<'a, ()>>,
}
/// Acquire an immediate write transaction with exclusive Rust session custody.
pub fn begin(session: &mut Session) -> driver::Result<WriteScope<'_>> {
    start(session, None)
}
/// Parallel MVCC transactions only for one original family and its shared budget.
/// All global mutations and final callbacks use `begin`, excluding these scopes.
pub fn begin_family<'a>(session: &'a mut Session, family: &str) -> driver::Result<WriteScope<'a>> {
    start(session, Some(family))
}
fn start<'a>(session: &'a mut Session, family: Option<&str>) -> driver::Result<WriteScope<'a>> {
    session.require_quiescent()?;
    let concurrent = session.owner.journal == super::Journal::Mvcc;
    let parallel = concurrent && family.is_some();
    let exclusive = if parallel || !concurrent {
        None
    } else {
        Some(session.owner.gate.write().map_err(super::owner::error)?)
    };
    let shared = if parallel {
        Some(session.owner.gate.read().map_err(super::owner::error)?)
    } else {
        None
    };
    let family = if parallel {
        family
            .map(|key| {
                session.owner.families[super::owner::stripe(key)]
                    .lock()
                    .map_err(super::owner::error)
            })
            .transpose()?
    } else {
        None
    };
    // The mutable Session borrow provides exclusive custody for the whole scope.
    let native = block_on(driver::transaction::Transaction::new_unchecked(
        &session.connection,
        if parallel {
            driver::transaction::TransactionBehavior::Concurrent
        } else {
            driver::transaction::TransactionBehavior::Immediate
        },
    ))?;
    Ok(WriteScope {
        connection: &session.connection,
        native: Some(native),
        poisoned: &session.poisoned,
        _exclusive: exclusive,
        _shared: shared,
        _family: family,
    })
}
impl WriteScope<'_> {
    /// Commit once; any failed result poisons this session against new writes.
    pub fn commit(mut self) -> driver::Result<()> {
        let native = self
            .native
            .take()
            .ok_or_else(|| driver::Error::Misuse("transaction already ended".into()))?;
        match block_on(native.commit()) {
            Ok(()) => Ok(()),
            Err(error) => {
                self.poisoned.store(true, Ordering::Release);
                if let Err(rollback_error) = release_failed_transaction(self.connection) {
                    return Err(driver::Error::BatchRollbackFailed {
                        error: Box::new(error),
                        rollback_error: Box::new(rollback_error),
                    });
                }
                Err(error)
            }
        }
    }
}
impl Deref for WriteScope<'_> {
    type Target = driver::Connection;
    fn deref(&self) -> &Self::Target {
        self.connection
    }
}
impl Drop for WriteScope<'_> {
    fn drop(&mut self) {
        if let Some(native) = self.native.take() {
            if block_on(native.rollback()).is_err() {
                self.poisoned.store(true, Ordering::Release);
                let _ = release_failed_transaction(self.connection);
            }
        } else if !matches!(self.connection.is_autocommit(), Ok(true)) {
            // Also cover unwinding while the native commit future owned the
            // transaction. Its deferred rollback must not strand the writer.
            self.poisoned.store(true, Ordering::Release);
            let _ = release_failed_transaction(self.connection);
        }
    }
}

fn release_failed_transaction(connection: &driver::Connection) -> driver::Result<()> {
    if connection.is_autocommit()? {
        return Ok(());
    }
    match block_on(connection.execute("ROLLBACK", ())) {
        Ok(_) => Ok(()),
        // Native deferred rollback can run before the explicit statement, leaving
        // no transaction for that statement. Accept only a verified idle state.
        Err(_) if matches!(connection.is_autocommit(), Ok(true)) => Ok(()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
#[path = "../../tests/unit/persistence_transactions.rs"]
mod tests;
