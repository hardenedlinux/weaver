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
    Admission,
    Other,
    PrepareRange,
    FinalQueue,
    RevalidateDelivery,
}

enum Change<'a> {
    Semantic,
    WorkflowObservation,
    Admission(&'a crate::provider::AdmissionRequest),
    Progress(&'a crate::provider::RangeProgress),
    Lifecycle(&'a crate::provider::OriginLifecycle),
}
/// Session-owned native transaction; compatible original origins may coexist.
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
    authority_entered: Instant,
    oauth_check: Cell<super::Timing>,
    current_domain: Cell<super::Timing>,
    current_pending: Cell<super::Timing>,
    current_review: Cell<super::Timing>,
    current_birth: Cell<super::Timing>,
    current_profile: Cell<super::Timing>,
    current_claim: Cell<super::Timing>,
    #[cfg(feature = "commit-observer")]
    claim_membership: Cell<super::Timing>,
    #[cfg(feature = "commit-observer")]
    manifest_reads: Cell<super::Timing>,
    #[cfg(feature = "commit-observer")]
    manifest_driver: [Cell<[u64; 8]>; 2],
    current_history: Cell<super::Timing>,
    current_manifest: Cell<super::Timing>,
    current_original: Cell<super::Timing>,
    #[cfg(feature = "commit-observer")]
    current_reservation: Cell<super::Timing>,
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
    start(
        session,
        None,
        None,
        ProviderScopePhase::Other,
        Change::Semantic,
    )
}
/// Parallel MVCC admission or final use for one original claim/budget/history family.
/// Global mutations use `begin`, excluding every live family scope through commit.
pub fn begin_family<'a>(session: &'a mut Session, family: &str) -> driver::Result<WriteScope<'a>> {
    start(
        session,
        Some(family),
        None,
        ProviderScopePhase::Other,
        Change::Semantic,
    )
}

/// Open the snapshot used to derive inert Workflow candidates.
pub(crate) fn begin_workflow_observation<'a>(
    session: &'a mut Session,
    family: &str,
) -> driver::Result<WriteScope<'a>> {
    start(
        session,
        Some(family),
        None,
        ProviderScopePhase::Other,
        Change::WorkflowObservation,
    )
}
/// Queued execution waits for its deciding turn before closing. MVCC rechecks
/// scheduler roots before SQL. WAL acquires the native writer before closing
/// and performs admission inside that transaction. Source changes, OAuth
/// intents and migration never use this entrypoint.
pub(crate) fn begin_provider_admission<'a>(
    session: &'a mut Session,
    family: &str,
    proof: &crate::provider::AdmissionRequest,
) -> driver::Result<WriteScope<'a>> {
    start(
        session,
        Some(family),
        None,
        ProviderScopePhase::Admission,
        Change::Admission(proof),
    )
}

/// Read custody remains the complete domain set. Only the sealed provider
/// lifecycle write set may invalidate its origin lane alone in MVCC.
pub(crate) fn begin_provider_lifecycle<'a>(
    session: &'a mut Session,
    family: &str,
    expected: Option<&weaver_contracts::DomainStamp>,
    phase: ProviderScopePhase,
    proof: &crate::provider::OriginLifecycle,
) -> driver::Result<WriteScope<'a>> {
    let expected = expected.filter(|_| !crate::task_origins::locked_original_evidence());
    start(
        session,
        Some(family),
        expected,
        phase,
        Change::Lifecycle(proof),
    )
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
    start(
        session,
        Some(family),
        expected,
        phase,
        Change::Progress(progress),
    )
}

fn start<'a>(
    session: &'a mut Session,
    family: Option<&str>,
    expected: Option<&weaver_contracts::DomainStamp>,
    phase: ProviderScopePhase,
    change: Change<'_>,
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
    let shared_reads = matches!(&change, Change::Progress(_) | Change::Lifecycle(_))
        && crate::provider::shared_provider_reads();
    #[cfg(any(test, feature = "commit-observer"))]
    let admission_request = matches!(&change, Change::Admission(_));
    let queued_admission = matches!(&change, Change::Admission(proof) if proof.wait_before_close());
    let selected_admission = concurrent && queued_admission;
    let wait_for_wal_writer = !concurrent
        && (queued_admission || matches!(&change, Change::Lifecycle(proof) if proof.origin_only()));
    let authority_entered = Instant::now();
    // Accepted source/Policy/OAuth intents close immediately, including while
    // waiting. WAL provider admission and exact lifecycle work may wait for
    // the native writer. Neither can use that transaction before closing.
    let authority = if selected_admission || wait_for_wal_writer {
        None
    } else {
        Some(match change {
            Change::Progress(proof) => session
                .owner
                .authority
                .close_progress(close_scope.clone(), proof)?,
            Change::Lifecycle(proof) => session
                .owner
                .authority
                .close_lifecycle(close_scope.clone(), proof)?,
            Change::Semantic | Change::WorkflowObservation | Change::Admission(_) => {
                session.owner.authority.close(close_scope.clone())?
            }
        })
    };
    #[cfg(any(test, feature = "commit-observer"))]
    if admission_request
        && let Some(observer) = &session.commit_observer
        && observer.admission_wait(family.expect("provider admission family"))
            != super::commit_observer::Decision::Continue
    {
        return Err(super::owner::error(
            "unaccepted provider admission abandoned before native scheduling",
        ));
    }
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
                ProviderScopePhase::Admission => session.range_cancelled.as_deref(),
                ProviderScopePhase::Other => None,
            };
            #[cfg(feature = "commit-observer")]
            let arrived = Instant::now();
            let grant = super::timing::measure(&mut session.timings.domain_wait, || {
                if shared_reads {
                    scheduler.acquire_origin(super::scheduler::Scope::Domains(keys), cancelled)
                } else {
                    scheduler.acquire(super::scheduler::Scope::Domains(keys), cancelled)
                }
            })?;
            domains_entered = Some(Instant::now());
            #[cfg(feature = "commit-observer")]
            if let Some(trace) = session.scope_trace.as_mut() {
                scope_trace = Some(
                    super::scope_trace::Arrival::capture(
                        phase,
                        grant.arrival,
                        arrived,
                        grant.origin_write,
                    )
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
    let authority = if selected_admission {
        let entered = Instant::now();
        Some((session.owner.authority.close(close_scope.clone())?, entered))
    } else {
        authority.map(|close| (close, authority_entered))
    };
    use driver::transaction::TransactionBehavior;
    let behavior = if concurrent && family.is_some() {
        TransactionBehavior::Concurrent
    } else if matches!(change, Change::WorkflowObservation) {
        TransactionBehavior::Deferred
    } else {
        TransactionBehavior::Immediate
    };
    // The mutable Session borrow provides exclusive custody for the whole scope.
    #[cfg(feature = "commit-observer")]
    let begin_before = session.timings.transaction_begin.nanos;
    #[cfg(feature = "commit-observer")]
    let driver_before = scope_trace
        .as_ref()
        .filter(|trace| trace.has_timeline())
        .map(|_| session.timings.begin_driver_counters());
    let native = begin_driver_transaction(
        &session.connection,
        behavior,
        &mut session.timings,
        #[cfg(feature = "commit-observer")]
        scope_trace.is_some(),
    )?;
    #[cfg(feature = "commit-observer")]
    if let Some(trace) = scope_trace.as_mut() {
        trace.opened(
            session
                .timings
                .transaction_begin
                .nanos
                .saturating_sub(begin_before),
            session.timings.commit.nanos,
            driver_before.map_or([0; 6], |before| {
                let after = session.timings.begin_driver_counters();
                std::array::from_fn(|i| after[i].saturating_sub(before[i]))
            }),
        );
    }
    let (authority, authority_entered) = if let Some(authority) = authority {
        authority
    } else {
        let entered = Instant::now();
        match session.owner.authority.close(close_scope) {
            Ok(authority) => (authority, entered),
            Err(error) => {
                if let Err(rollback_error) =
                    super::timing::measure(&mut session.timings.rollback, || {
                        block_on(native.rollback())
                    })
                {
                    session.poisoned.store(true, Ordering::Release);
                    let _ = release_failed_transaction(&session.connection);
                    return Err(driver::Error::BatchRollbackFailed {
                        error: Box::new(error),
                        rollback_error: Box::new(rollback_error),
                    });
                }
                return Err(error);
            }
        }
    };
    Ok(WriteScope {
        connection: &session.connection,
        authority,
        quota_projection: &session.owner.quota_projection,
        quota_update: None,
        native: Some(native),
        poisoned: &session.poisoned,
        timings: &mut session.timings,
        entered: Instant::now(),
        authority_entered,
        oauth_check: Cell::default(),
        current_domain: Cell::default(),
        current_pending: Cell::default(),
        current_review: Cell::default(),
        current_birth: Cell::default(),
        current_profile: Cell::default(),
        current_claim: Cell::default(),
        #[cfg(feature = "commit-observer")]
        claim_membership: Cell::default(),
        #[cfg(feature = "commit-observer")]
        manifest_reads: Cell::default(),
        #[cfg(feature = "commit-observer")]
        manifest_driver: Default::default(),
        current_history: Cell::default(),
        current_manifest: Cell::default(),
        current_original: Cell::default(),
        #[cfg(feature = "commit-observer")]
        current_reservation: Cell::default(),
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

fn begin_driver_transaction<'a>(
    connection: &'a driver::Connection,
    behavior: driver::transaction::TransactionBehavior,
    timings: &mut super::TransactionTimings,
    #[cfg(feature = "commit-observer")] observed: bool,
) -> driver::Result<driver::transaction::Transaction<'a>> {
    let future = driver::transaction::Transaction::new_unchecked(connection, behavior);
    super::timing::measure(&mut timings.transaction_begin, || {
        #[cfg(feature = "commit-observer")]
        if observed {
            use super::driver_observer::{DriverSpan, observe};
            let (result, prepare, prepare_cpu) = observe(DriverSpan::Prepare, || {
                super::timing::observe_polls(
                    future,
                    &mut timings.transaction_begin_poll,
                    &mut timings.transaction_begin_cpu,
                    &mut timings.transaction_begin_pending,
                )
            });
            timings.transaction_begin_prepare.merge(prepare);
            timings.transaction_begin_prepare_cpu.merge(prepare_cpu);
            return result;
        }
        block_on(future)
    })
}
fn commit_driver_transaction(
    native: driver::transaction::Transaction<'_>,
    timings: &mut super::TransactionTimings,
    #[cfg(feature = "commit-observer")] observed: Option<&mut super::scope_trace::Granted<'_>>,
) -> driver::Result<()> {
    let future = native.commit();
    super::timing::measure(&mut timings.commit, || {
        #[cfg(feature = "commit-observer")]
        if let Some(trace) = observed {
            use super::driver_observer::observe_commit;
            let (result, sync, io) = observe_commit(trace.has_timeline(), || {
                super::timing::observe_polls(
                    future,
                    &mut timings.commit_poll,
                    &mut timings.commit_cpu,
                    &mut timings.commit_pending,
                )
            });
            timings.commit_sync.merge(sync);
            trace.committed_io(io);
            return result;
        }
        block_on(future)
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
    pub(crate) fn commit_provider_admission(self) -> driver::Result<()> {
        self.commit_observed::<5>()
    }
    pub(crate) fn commit_lifecycle(self) -> driver::Result<()> {
        self.commit_observed::<4>()
    }
    pub(crate) fn commit_delivery_refresh(self) -> driver::Result<()> {
        self.commit_observed::<3>()
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
                5 => (Cut::BeforeAdmissionCommit, Cut::AfterAdmissionCommit),
                4 => (Cut::BeforeLifecycleCommit, Cut::AfterLifecycleCommit),
                3 => (
                    Cut::BeforeSnapshotPublication,
                    Cut::AfterSnapshotPublication,
                ),
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
            self.commit_turso(PHASE != 3)?;
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
        self.commit_turso(PHASE != 3)
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
    pub(crate) fn provider_claim_membership<T>(&self, run: impl FnOnce() -> T) -> T {
        #[cfg(feature = "commit-observer")]
        if self
            .scope_trace
            .as_ref()
            .is_some_and(|trace| trace.has_timeline())
        {
            return observe(&self.claim_membership, run);
        }
        run()
    }
    pub(crate) fn provider_manifest_reads<T>(&self, run: impl FnOnce() -> T) -> T {
        #[cfg(feature = "commit-observer")]
        if self
            .scope_trace
            .as_ref()
            .is_some_and(|trace| trace.has_timeline())
        {
            return observe(&self.manifest_reads, run);
        }
        run()
    }
    #[cfg(feature = "commit-observer")]
    pub(super) fn observe_manifest_driver<F: std::future::Future>(
        &self,
        projected: bool,
        future: F,
    ) -> F::Output {
        if !self
            .scope_trace
            .as_ref()
            .is_some_and(|trace| trace.has_timeline())
        {
            return block_on(future);
        }
        let (result, sample) = super::driver_observer::observe_read(future);
        let counter = &self.manifest_driver[usize::from(projected)];
        let previous = counter.get();
        counter.set(std::array::from_fn(|i| {
            previous[i].saturating_add(sample[i])
        }));
        result
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
    #[cfg(feature = "commit-observer")]
    pub(crate) fn provider_reservation<T>(&self, run: impl FnOnce() -> T) -> T {
        if self
            .scope_trace
            .as_ref()
            .is_some_and(|trace| trace.has_timeline())
        {
            observe(&self.current_reservation, run)
        } else {
            run()
        }
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
        match commit_driver_transaction(
            native,
            self.timings,
            #[cfg(feature = "commit-observer")]
            self.scope_trace.as_mut(),
        ) {
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
        let transaction_hold = self.entered.elapsed();
        self.timings.transaction_hold.record(transaction_hold);
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
        self.timings
            .authority_span
            .record(self.authority_entered.elapsed());
        #[cfg(feature = "commit-observer")]
        let releasing = self.scope_trace.as_ref().map(|_| Instant::now());
        #[cfg(feature = "commit-observer")]
        let release = if self
            .scope_trace
            .as_ref()
            .is_some_and(|trace| trace.has_timeline())
        {
            super::scope_trace::observe_release(|| drop(self.grant.take()))
        } else {
            drop(self.grant.take());
            None
        };
        #[cfg(not(feature = "commit-observer"))]
        drop(self.grant.take());
        if let Some(entered) = self.domains_entered {
            self.timings.domain_hold.record(entered.elapsed());
        }
        if let Some(entered) = self.owner_entered {
            self.timings.owner_gate_hold.record(entered.elapsed());
        }
        #[cfg(feature = "commit-observer")]
        if let (Some(trace), Some(releasing)) = (self.scope_trace.take(), releasing) {
            trace.record(super::scope_trace::Completion {
                authority_span: self.authority_entered.elapsed(),
                releasing,
                transaction_nanos: u64::try_from(transaction_hold.as_nanos()).unwrap_or(u64::MAX),
                commit_total: self.timings.commit.nanos,
                admission_nanos: [
                    self.current_claim.get().nanos,
                    self.current_original.get().nanos,
                    self.current_manifest.get().nanos,
                    self.current_history.get().nanos,
                    self.current_reservation.get().nanos,
                    self.cedar.get().nanos,
                    self.claim_membership.get().nanos,
                    self.manifest_reads.get().nanos,
                ],
                manifest_driver: self.manifest_driver.each_ref().map(Cell::get),
                release,
            });
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
