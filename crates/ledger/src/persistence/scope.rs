// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Explicit commit and eager rollback of one native `Turso` write transaction.
use super::{Session, driver};
use futures_executor::block_on;
use std::{
    cell::Cell,
    ops::Deref,
    sync::atomic::{AtomicBool, Ordering},
    sync::{MutexGuard, RwLockReadGuard, RwLockWriteGuard},
    time::Instant,
};

/// Exclusive native transaction; final guarded callbacks keep this scope alive.
pub struct WriteScope<'a> {
    connection: &'a driver::Connection,
    native: Option<driver::transaction::Transaction<'a>>,
    poisoned: &'a AtomicBool,
    timings: &'a mut super::TransactionTimings,
    entered: Instant,
    oauth_check: Cell<super::Timing>,
    owner_entered: Option<Instant>,
    domains_entered: Option<Instant>,
    _exclusive: Option<RwLockWriteGuard<'a, ()>>,
    _shared: Option<RwLockReadGuard<'a, ()>>,
    _domains: Vec<MutexGuard<'a, ()>>,
    #[cfg(any(test, feature = "commit-observer"))]
    observer: Option<std::sync::Arc<dyn super::commit_observer::Observer>>,
}
/// Acquire an immediate write transaction with exclusive Rust session custody.
pub fn begin(session: &mut Session) -> driver::Result<WriteScope<'_>> {
    start(session, None)
}
/// Parallel MVCC admission or final use for one original claim/budget/history family.
/// Global mutations use `begin`, excluding every live family scope through commit.
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
        Some(
            super::timing::measure(&mut session.timings.owner_gate_wait, || {
                session.owner.gate.write()
            })
            .map_err(super::owner::error)?,
        )
    };
    let shared = if parallel {
        Some(
            super::timing::measure(&mut session.timings.owner_gate_wait, || {
                session.owner.gate.read()
            })
            .map_err(super::owner::error)?,
        )
    } else {
        None
    };
    let owner_entered = (exclusive.is_some() || shared.is_some()).then(Instant::now);
    let domains = if parallel {
        let keys = super::timing::measure(&mut session.timings.domain_keys, || {
            crate::domains::lock_keys(&session.connection, family.unwrap_or_default())
        })?;
        let mut stripes: Vec<usize> = keys.iter().map(|key| super::owner::stripe(key)).collect();
        stripes.sort_unstable();
        stripes.dedup();
        super::timing::measure(&mut session.timings.domain_wait, || {
            stripes
                .into_iter()
                .map(|index| {
                    session.owner.families[index]
                        .lock()
                        .map_err(super::owner::error)
                })
                .collect::<driver::Result<Vec<_>>>()
        })?
    } else {
        Vec::new()
    };
    let domains_entered = parallel.then(Instant::now);
    // The mutable Session borrow provides exclusive custody for the whole scope.
    let native = super::timing::measure(&mut session.timings.transaction_begin, || {
        block_on(driver::transaction::Transaction::new_unchecked(
            &session.connection,
            if parallel {
                driver::transaction::TransactionBehavior::Concurrent
            } else {
                driver::transaction::TransactionBehavior::Immediate
            },
        ))
    })?;
    Ok(WriteScope {
        connection: &session.connection,
        native: Some(native),
        poisoned: &session.poisoned,
        timings: &mut session.timings,
        entered: Instant::now(),
        oauth_check: Cell::new(super::Timing::default()),
        owner_entered,
        domains_entered,
        _exclusive: exclusive,
        _shared: shared,
        _domains: domains,
        #[cfg(any(test, feature = "commit-observer"))]
        observer: session.commit_observer.clone(),
    })
}
impl WriteScope<'_> {
    pub(crate) fn commit_provider(self) -> driver::Result<()> {
        #[cfg(any(test, feature = "commit-observer"))]
        {
            use super::commit_observer::{Cut, Decision};
            let observer = self.observer.clone();
            let poisoned = self.poisoned;
            if let Some(observer) = &observer
                && observer.observe(Cut::BeforeCommit) != Decision::Continue
            {
                let mut scope = self;
                poisoned.store(true, Ordering::Release);
                let native = scope
                    .native
                    .take()
                    .ok_or_else(|| driver::Error::Misuse("transaction ended".into()))?;
                block_on(native.rollback())?;
                return Err(driver::Error::Misuse(
                    "injected native rollback before provider commit".into(),
                ));
            }
            // commit consumes the scope and releases every owner/domain lock BEFORE
            // the acknowledgment observation. A new fence may commit during this gap.
            self.commit()?;
            if let Some(observer) = observer
                && observer.observe(Cut::AfterCommit) != Decision::Continue
            {
                poisoned.store(true, Ordering::Release);
                return Err(driver::Error::Misuse(
                    "native provider commit applied; acknowledgment unavailable".into(),
                ));
            }
            Ok(())
        }
        #[cfg(not(any(test, feature = "commit-observer")))]
        self.commit()
    }
    pub(crate) fn check_provider_oauth(
        &self,
        evidence: Option<&crate::provider_oauth::PreparedUse>,
    ) -> weaver_contracts::Result<Option<u64>> {
        let started = Instant::now();
        let result = crate::provider_oauth::require(self, evidence);
        let mut timing = self.oauth_check.get();
        timing.record(started.elapsed());
        self.oauth_check.set(timing);
        result
    }

    pub(crate) fn request_effect<T>(&mut self, run: impl FnOnce() -> T) -> T {
        super::timing::measure(&mut self.timings.provider_request, run)
    }
    pub(crate) fn queue_effect<T>(&mut self, run: impl FnOnce() -> T) -> T {
        super::timing::measure(&mut self.timings.provider_queue, run)
    }
    /// Commit once; any failed result poisons this session against new writes.
    pub fn commit(mut self) -> driver::Result<()> {
        let native = self
            .native
            .take()
            .ok_or_else(|| driver::Error::Misuse("transaction already ended".into()))?;
        match super::timing::measure(&mut self.timings.commit, || block_on(native.commit())) {
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
            if super::timing::measure(&mut self.timings.rollback, || block_on(native.rollback()))
                .is_err()
            {
                self.poisoned.store(true, Ordering::Release);
                let _ = release_failed_transaction(self.connection);
            }
        } else if !matches!(self.connection.is_autocommit(), Ok(true)) {
            // Also cover unwinding while the native commit future owned the
            // transaction. Its deferred rollback must not strand the writer.
            self.poisoned.store(true, Ordering::Release);
            let _ = release_failed_transaction(self.connection);
        }
        self.timings.transaction_hold.record(self.entered.elapsed());
        let sample = self.oauth_check.get();
        let total = &mut self.timings.provider_oauth_check;
        total.attempts = total.attempts.saturating_add(sample.attempts);
        total.nanos = total.nanos.saturating_add(sample.nanos);
        self._domains.clear();
        if let Some(entered) = self.domains_entered {
            self.timings.domain_hold.record(entered.elapsed());
        }
        drop(self._shared.take());
        drop(self._exclusive.take());
        if let Some(entered) = self.owner_entered {
            self.timings.owner_gate_hold.record(entered.elapsed());
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
