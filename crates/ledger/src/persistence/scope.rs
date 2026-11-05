// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Explicit commit and eager rollback of one native `Turso` write transaction.
use super::{Session, authority::Outcome, driver};
use futures_executor::block_on;
use std::{
    cell::Cell,
    ops::Deref,
    sync::atomic::{AtomicBool, Ordering},
    time::Instant,
};

/// Provider range phase used to label diagnostic scope observations.
#[derive(Clone, Copy)]
pub enum ProviderScopePhase {
    Other,
    PrepareRange,
    FinalQueue,
    RevalidateDelivery,
}

/// Exclusive native transaction; final guarded callbacks keep this scope alive.
pub struct WriteScope<'a> {
    connection: &'a driver::Connection,
    authority: super::authority::Close<'a>,
    quota_projection:
        &'a std::sync::Mutex<Option<std::sync::Arc<weaver_contracts::MeteringDeployment>>>,
    quota_update: Option<std::sync::Arc<weaver_contracts::MeteringDeployment>>,
    native: Option<driver::transaction::Transaction<'a>>,
    poisoned: &'a AtomicBool,
    timings: &'a mut super::TransactionTimings,
    entered: Instant,
    oauth_check: Cell<super::Timing>,
    current_domain: Cell<super::Timing>,
    current_pending: Cell<super::Timing>,
    current_review: Cell<super::Timing>,
    current_birth: Cell<super::Timing>,
    current_profile: Cell<super::Timing>,
    current_claim: Cell<super::Timing>,
    current_history: Cell<super::Timing>,
    current_manifest: Cell<super::Timing>,
    current_original: Cell<super::Timing>,
    cedar: Cell<super::Timing>,
    owner_entered: Option<Instant>,
    domains_entered: Option<Instant>,
    #[cfg(feature = "commit-observer")]
    scope_trace: Option<super::scope_trace::Granted<'a>>,
    grant: Option<super::scheduler::Grant<'a>>,
    #[cfg(any(test, feature = "commit-observer"))]
    observer: Option<std::sync::Arc<dyn super::commit_observer::Observer>>,
}
/// Acquire an immediate write transaction with exclusive Rust session custody.
pub fn begin(session: &mut Session) -> driver::Result<WriteScope<'_>> {
    start(session, None, None, ProviderScopePhase::Other, None)
}
/// Parallel MVCC admission or final use for one original claim/budget/history family.
/// Global mutations use `begin`, excluding every live family scope through commit.
pub fn begin_family<'a>(session: &'a mut Session, family: &str) -> driver::Result<WriteScope<'a>> {
    start(session, Some(family), None, ProviderScopePhase::Other, None)
}
/// The caller must rejoin the live stamp in this scope before any effect.
pub(crate) fn begin_provider_use<'a>(
    session: &'a mut Session,
    family: &str,
    expected: &weaver_contracts::DomainStamp,
    phase: ProviderScopePhase,
) -> driver::Result<WriteScope<'a>> {
    let expected = (!crate::task_origins::locked_original_evidence()).then_some(expected);
    start(session, Some(family), expected, phase, None)
}

/// The sealed token is constructed only in provider's exact progress paths.
pub(crate) fn begin_provider_progress<'a>(
    session: &'a mut Session,
    family: &str,
    expected: &weaver_contracts::DomainStamp,
    phase: ProviderScopePhase,
    progress: &crate::provider::RangeProgress,
) -> driver::Result<WriteScope<'a>> {
    let expected = (!crate::task_origins::locked_original_evidence()).then_some(expected);
    start(session, Some(family), expected, phase, Some(progress))
}

fn start<'a>(
    session: &'a mut Session,
    family: Option<&str>,
    expected: Option<&weaver_contracts::DomainStamp>,
    phase: ProviderScopePhase,
    progress: Option<&crate::provider::RangeProgress>,
) -> driver::Result<WriteScope<'a>> {
    session.require_quiescent()?;
    let concurrent = session.owner.journal == super::Journal::Mvcc;
    let scheduler = &session.owner.scheduler;
    // Capture discovery generation BEFORE the hint query. A migration between
    // key discovery and grant must never look like a current scheduler image.
    let discovered = (concurrent && family.is_some())
        .then(|| scheduler.generation())
        .transpose()?;
    let keys = match (concurrent, family) {
        (true, Some(family)) => Some(session.owner.scope_roots(
            super::timing::measure(&mut session.timings.domain_keys, || match expected {
                Some(stamp) => Ok(crate::domains::stamp_keys(stamp)),
                None => crate::domains::lock_keys(&session.connection, family),
            })?,
            family,
        )?),
        _ => None,
    };
    let close_scope = keys.as_ref().map_or(super::scheduler::Scope::All, |keys| {
        super::scheduler::Scope::Domains(keys.clone())
    });
    // Close before waiting for either the scheduler or native writer.
    let authority = match progress {
        Some(progress) => session
            .owner
            .authority
            .close_progress(close_scope, progress)?,
        None => session.owner.authority.close(close_scope)?,
    };
    let mut owner_entered = None;
    let mut domains_entered = None;
    #[cfg(feature = "commit-observer")]
    let mut scope_trace = None;
    let grant = match (concurrent, family) {
        (true, Some(family)) => {
            let keys = keys.expect("family scheduler keys");
            let cancelled = match phase {
                ProviderScopePhase::PrepareRange
                | ProviderScopePhase::FinalQueue
                | ProviderScopePhase::RevalidateDelivery => session.range_cancelled.as_deref(),
                ProviderScopePhase::Other => None,
            };
            #[cfg(feature = "commit-observer")]
            let arrived = Instant::now();
            let grant = super::timing::measure(&mut session.timings.domain_wait, || {
                scheduler.acquire(super::scheduler::Scope::Domains(keys), cancelled)
            })?;
            domains_entered = Some(Instant::now());
            #[cfg(feature = "commit-observer")]
            if let Some(trace) = session.scope_trace.as_mut() {
                scope_trace = Some(
                    super::scope_trace::Arrival::capture(phase, grant.arrival, arrived)
                        .granted(trace, grant.granted),
                );
            }
            // Key discovery is a hint. An intervening global scope may have migrated roots.
            if discovered.is_some_and(|generation| generation != grant.generation)
                && !grant.matches_domains(&session.owner.scope_roots(
                    crate::domains::lock_keys(&session.connection, family)?,
                    family,
                )?)?
            {
                return Err(super::owner::error(
                    "execution domains changed before scheduler grant",
                ));
            }
            Some(grant)
        }
        (true, None) => {
            let grant = super::timing::measure(&mut session.timings.owner_gate_wait, || {
                scheduler.acquire(super::scheduler::Scope::All, None)
            })?;
            owner_entered = Some(Instant::now());
            Some(grant)
        }
        (false, _) => None,
    };
    let parallel = concurrent && family.is_some();
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
        authority,
        quota_projection: &session.owner.quota_projection,
        quota_update: None,
        native: Some(native),
        poisoned: &session.poisoned,
        timings: &mut session.timings,
        entered: Instant::now(),
        oauth_check: Cell::default(),
        current_domain: Cell::default(),
        current_pending: Cell::default(),
        current_review: Cell::default(),
        current_birth: Cell::default(),
        current_profile: Cell::default(),
        current_claim: Cell::default(),
        current_history: Cell::default(),
        current_manifest: Cell::default(),
        current_original: Cell::default(),
        cedar: Cell::default(),
        owner_entered,
        domains_entered,
        #[cfg(feature = "commit-observer")]
        scope_trace,
        grant,
        #[cfg(any(test, feature = "commit-observer"))]
        observer: session.commit_observer.clone(),
    })
}
impl WriteScope<'_> {
    pub(crate) fn project_metering(
        &mut self,
        config: Option<weaver_contracts::MeteringDeployment>,
    ) {
        self.quota_update = config.map(std::sync::Arc::new);
    }

    pub(crate) fn delivery_scope(&self) -> super::scheduler::Scope {
        self.authority.scope()
    }
    pub(crate) fn refresh_delivery_receipt(
        &mut self,
        receipt: std::sync::Arc<super::authority::Completion>,
    ) {
        self.authority.replace_receipt(receipt);
    }
    pub(crate) fn commit_delivery_refresh(self) -> driver::Result<()> {
        self.commit_turso(false)
    }
    pub(crate) fn witness_started(&self, path: &str) -> driver::Result<()> {
        self.authority.external(path, false)
    }
    pub(crate) fn witness_reconciled(&self, path: &str) -> driver::Result<()> {
        self.authority.external(path, true)
    }
    pub(crate) fn delivery_receipt(
        &mut self,
    ) -> driver::Result<std::sync::Arc<super::authority::Completion>> {
        self.authority.receipt()
    }
    pub(crate) fn commit_provider(self) -> driver::Result<()> {
        self.commit_observed::<0>()
    }

    pub(crate) fn commit_range_prepare(self) -> driver::Result<()> {
        self.commit_observed::<1>()
    }

    pub(crate) fn commit_delivery(self) -> driver::Result<()> {
        self.commit_observed::<2>()
    }

    fn commit_observed<const PHASE: u8>(self) -> driver::Result<()> {
        #[cfg(any(test, feature = "commit-observer"))]
        {
            use super::commit_observer::{Cut, Decision};
            let observer = self.observer.clone();
            let (before, after) = match PHASE {
                1 => (Cut::BeforeRangePrepareCommit, Cut::AfterRangePrepareCommit),
                2 => (Cut::BeforeDeliveryCommit, Cut::AfterDeliveryCommit),
                _ => (Cut::BeforeCommit, Cut::AfterCommit),
            };
            let poisoned = self.poisoned;
            if let Some(observer) = &observer
                && observer.observe(before) != Decision::Continue
            {
                let mut scope = self;
                poisoned.store(true, Ordering::Release);
                let native = scope
                    .native
                    .take()
                    .ok_or_else(|| driver::Error::Misuse("transaction ended".into()))?;
                scope.authority.committing();
                block_on(native.rollback())?;
                scope.authority.finish(Outcome::Absent)?;
                return Err(driver::Error::Misuse(
                    "injected native rollback before provider commit".into(),
                ));
            }
            // commit consumes the scope and releases every owner/domain lock BEFORE
            // the acknowledgment observation. A new fence may commit during this gap.
            self.commit()?;
            if let Some(observer) = observer
                && observer.observe(after) != Decision::Continue
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
        observe(&self.oauth_check, || {
            crate::provider_oauth::require(self, evidence)
        })
    }
    pub(crate) fn provider_domain<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_domain, run)
    }
    pub(crate) fn provider_pending<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_pending, run)
    }
    pub(crate) fn provider_review<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_review, run)
    }
    pub(crate) fn provider_birth<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_birth, run)
    }
    pub(crate) fn provider_profile<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_profile, run)
    }
    pub(crate) fn provider_claim<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_claim, run)
    }
    pub(crate) fn provider_original<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_original, run)
    }
    pub(crate) fn provider_manifest<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_manifest, run)
    }
    pub(crate) fn provider_history<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.current_history, run)
    }
    pub(crate) fn provider_cedar<T>(&self, run: impl FnOnce() -> T) -> T {
        observe(&self.cedar, run)
    }

    pub(crate) fn request_effect<T>(&mut self, run: impl FnOnce() -> T) -> T {
        super::timing::measure(&mut self.timings.provider_request, run)
    }
    pub(crate) fn queue_effect<T>(&mut self, run: impl FnOnce() -> T) -> T {
        super::timing::measure(&mut self.timings.provider_queue, run)
    }
    /// Commit once; any failed result poisons this session against new writes.
    pub fn commit(self) -> driver::Result<()> {
        self.commit_turso(true)
    }
    fn commit_turso(mut self, modified: bool) -> driver::Result<()> {
        self.authority.committing();
        let native = self
            .native
            .take()
            .ok_or_else(|| driver::Error::Misuse("transaction already ended".into()))?;
        match super::timing::measure(&mut self.timings.commit, || block_on(native.commit())) {
            Ok(()) => {
                if let Some(config) = self.quota_update.take() {
                    *self.quota_projection.lock().map_err(super::owner::error)? = Some(config);
                }
                self.authority.finish(Outcome::Committed { modified })
            }
            Err(error) => {
                self.poisoned.store(true, Ordering::Release);
                // An exclusive connection still inside the original native
                // transaction plus successful rollback proves DB absence.
                // An idle connection proves neither commit nor absence.
                let active = matches!(self.connection.is_autocommit(), Ok(false));
                let cleanup = release_failed_transaction(self.connection);
                let _ = self.authority.finish(if active && cleanup.is_ok() {
                    Outcome::Absent
                } else {
                    Outcome::Unknown
                });
                if let Err(rollback_error) = cleanup {
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
fn observe<T>(timing: &Cell<super::Timing>, run: impl FnOnce() -> T) -> T {
    let mut sample = timing.get();
    let result = super::timing::measure(&mut sample, run);
    timing.set(sample);
    result
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
                let _ = self.authority.finish(Outcome::Unknown);
            } else {
                let _ = self.authority.finish(Outcome::Absent);
            }
        } else if !matches!(self.connection.is_autocommit(), Ok(true)) {
            // Also cover unwinding while the native commit future owned the
            // transaction. Its deferred rollback must not strand the writer.
            self.poisoned.store(true, Ordering::Release);
            let _ = release_failed_transaction(self.connection);
        }
        self.timings.transaction_hold.record(self.entered.elapsed());
        for (total, sample) in [
            (
                &mut self.timings.provider_oauth_check,
                self.oauth_check.get(),
            ),
            (&mut self.timings.provider_domain, self.current_domain.get()),
            (
                &mut self.timings.provider_pending,
                self.current_pending.get(),
            ),
            (&mut self.timings.provider_review, self.current_review.get()),
            (&mut self.timings.provider_birth, self.current_birth.get()),
            (
                &mut self.timings.provider_profile,
                self.current_profile.get(),
            ),
            (&mut self.timings.provider_claim, self.current_claim.get()),
            (
                &mut self.timings.provider_history,
                self.current_history.get(),
            ),
            (
                &mut self.timings.provider_manifest,
                self.current_manifest.get(),
            ),
            (
                &mut self.timings.provider_original,
                self.current_original.get(),
            ),
            (&mut self.timings.provider_cedar, self.cedar.get()),
        ] {
            total.attempts = total.attempts.saturating_add(sample.attempts);
            total.nanos = total.nanos.saturating_add(sample.nanos);
        }
        self.authority.settle_drop();
        drop(self.grant.take());
        if let Some(entered) = self.domains_entered {
            self.timings.domain_hold.record(entered.elapsed());
        }
        if let Some(entered) = self.owner_entered {
            self.timings.owner_gate_hold.record(entered.elapsed());
        }
        #[cfg(feature = "commit-observer")]
        if let Some(trace) = self.scope_trace.take() {
            trace.record();
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
