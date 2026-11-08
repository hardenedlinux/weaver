// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Inert gRPC frames join acknowledged Turso validation at the receiver owner.
use crate::{
    Ledger, ProviderDispatch, db,
    persistence::{
        authority::{Completion, Receipt},
        owner::Owner,
        scheduler::Scope,
    },
};
use std::{
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, Instant},
};
use weaver_contracts::{Error, ProviderPlan, Result};

struct SnapshotRange {
    first: u64,
    rows: u64,
    digest: String,
}
struct Snapshot {
    completion: Arc<Completion>,
    manifest: Vec<SnapshotRange>,
}
struct Binding {
    snapshot: Arc<Snapshot>,
    owner: Arc<Owner>,
    completion: Arc<Completion>,
    scope: Scope,
    session: String,
    plan: String,
    format: String,
    first: u64,
    rows: u64,
    validity: Option<std::ops::Range<u64>>,
}
/// Issued only from the existing live range guard; not permission to send.
pub struct ProviderDelivery(Arc<Binding>);
/// Producer role may confirm/requalify; it cannot consume the receiver cursor.
pub struct DeliveryProducer(Arc<Binding>);
/// Sole receiver role. This value is intentionally not Clone.
pub struct DeliveryFrame(Arc<Binding>);
/// The unique receiver owns the next interval and the original request binding.
pub struct DeliveryCursor {
    plan: String,
    session: Option<String>,
    next: u64,
    owner: Option<Arc<Owner>>,
}
/// Producer progress at the acknowledged final delivery boundary.
#[derive(Debug, PartialEq, Eq)]
pub enum DeliveryWait {
    Refresh,
    Accepted,
}
/// Exact logical row interval, independent of the Protobuf or Arrow encoding.
#[derive(Debug, PartialEq, Eq)]
pub struct DeliveryInterval {
    pub first: u64,
    pub rows: u64,
}
impl ProviderDelivery {
    pub(crate) fn group(
        owner: Arc<Owner>,
        completion: Arc<Completion>,
        scope: Scope,
        permit: &ProviderDispatch,
        releases: &[crate::ProviderRelease],
        format: &str,
    ) -> Vec<Self> {
        let snapshot = Arc::new(Snapshot {
            completion: completion.clone(),
            manifest: releases
                .iter()
                .map(|release| SnapshotRange {
                    first: release.sequence,
                    rows: release.length,
                    digest: release.digest.clone(),
                })
                .collect(),
        });
        releases
            .iter()
            .enumerate()
            .map(|(index, release)| {
                Self(Arc::new(Binding {
                    snapshot: snapshot.clone(),
                    owner: owner.clone(),
                    completion: if index == 0 {
                        completion.clone()
                    } else {
                        Arc::new(completion.share_qualification())
                    },
                    scope: scope.clone(),
                    session: permit.session.clone(),
                    plan: permit.digest.clone(),
                    format: format.to_owned(),
                    first: release.sequence,
                    rows: release.length,
                    validity: permit
                        .oauth
                        .as_ref()
                        .map(crate::provider_oauth::PreparedUse::validity),
                }))
            })
            .collect()
    }
    pub fn split(self) -> (DeliveryProducer, DeliveryFrame) {
        (DeliveryProducer(self.0.clone()), DeliveryFrame(self.0))
    }
    pub fn interval(&self) -> DeliveryInterval {
        DeliveryInterval {
            first: self.0.first,
            rows: self.0.rows,
        }
    }
}
impl DeliveryProducer {
    /// Register a reactor wake for receipt consumption, refresh or rejection.
    /// The producer must still recheck the actual state with `progress`.
    pub fn poll_progress_ready(&self, cx: &Context<'_>) -> Poll<()> {
        let Ok(mut receipt) = self.0.completion.state.lock() else {
            return Poll::Ready(());
        };
        if receipt.consumed || receipt.refresh || receipt.rejected {
            return Poll::Ready(());
        }
        receipt.producer_waker = Some(cx.waker().clone());
        Poll::Pending
    }
    pub fn acknowledge(&self, deadline: Instant) -> Result<()> {
        let mut receipt = self
            .0
            .completion
            .state
            .lock()
            .map_err(|_| Error::Conflict("delivery poisoned"))?;
        if receipt.rejected || !self.0.completion.confirmed().map_err(db)? {
            return Err(Error::Conflict("delivery commit unconfirmed"));
        }
        receipt.deadline.get_or_insert(deadline);
        #[cfg(feature = "commit-observer")]
        receipt
            .acknowledged_at
            .get_or_insert_with(std::time::SystemTime::now);
        receipt.acknowledged = true;
        let waker = receipt.waker.take();
        drop(receipt);
        if let Some(waker) = waker {
            waker.wake();
        }
        Ok(())
    }
    /// Nonblocking producer progress. A refresh requests the existing live guard;
    /// it neither grants a transfer nor changes the original deadline.
    pub fn progress(&self) -> Result<Option<DeliveryWait>> {
        let receipt = self
            .0
            .completion
            .state
            .lock()
            .map_err(|_| Error::Conflict("delivery poisoned"))?;
        if receipt.consumed {
            return Ok(Some(DeliveryWait::Accepted));
        }
        if receipt.rejected
            || receipt
                .deadline
                .is_some_and(|deadline| Instant::now() >= deadline)
        {
            return Err(Error::Conflict("delivery cancelled or expired"));
        }
        if receipt.refresh {
            drop(receipt);
            return Ok(self
                .0
                .owner
                .authority
                .take_refresh(&self.0.scope, &self.0.completion)?
                .then_some(DeliveryWait::Refresh));
        }
        Ok(None)
    }
    /// No engine lock is retained across this bounded blocking producer wait.
    pub fn wait(&self, cancelled: impl Fn() -> bool, deadline: Instant) -> Result<DeliveryWait> {
        let completion = &self.0.completion;
        loop {
            if let Some(progress) = self.progress()? {
                return Ok(progress);
            }
            let receipt = completion
                .state
                .lock()
                .map_err(|_| Error::Conflict("delivery poisoned"))?;
            if receipt.consumed || receipt.refresh || receipt.rejected {
                continue;
            }
            if cancelled() || Instant::now() >= deadline {
                return Err(Error::Conflict("delivery cancelled or unavailable"));
            }
            let (receipt, _) = completion
                .changed
                .wait_timeout(receipt, Duration::from_millis(5))
                .map_err(|_| Error::Conflict("delivery poisoned"))?;
            drop(receipt);
        }
    }
}
impl Drop for DeliveryProducer {
    fn drop(&mut self) {
        if let Ok(mut receipt) = self.0.completion.state.lock() {
            if !receipt.consumed {
                receipt.rejected = true;
            }
            if let Some(waker) = receipt.waker.take() {
                waker.wake();
            }
            self.0.completion.changed.notify_all();
        }
    }
}
#[cfg(feature = "commit-observer")]
impl DeliveryFrame {
    /// Test-host observation only; this value cannot authorize a transfer.
    pub fn acknowledged(&self) -> bool {
        self.0
            .completion
            .state
            .lock()
            .is_ok_and(|receipt| receipt.acknowledged)
    }
}
impl DeliveryCursor {
    pub fn new(plan: &ProviderPlan) -> Result<Self> {
        Ok(Self {
            plan: plan.digest()?,
            session: None,
            next: 0,
            owner: None,
        })
    }
    /// The immutable frame moves into the Poll::Ready return value under the
    /// authority mutex. There is no second authorized queue after this turn.
    pub fn poll<T>(
        &mut self,
        proof: &DeliveryFrame,
        cx: &Context<'_>,
        payload: &mut Option<T>,
    ) -> Poll<Result<T>> {
        let binding = &proof.0;
        let result = binding.owner.authority.current(
            &binding.scope,
            &binding.completion,
            cx.waker(),
            |receipt| self.accept_current_frame(binding, receipt, payload),
        );
        match result {
            Ok(Some(value)) => Poll::Ready(Ok(value)),
            Ok(None) => Poll::Pending,
            Err(error) => Poll::Ready(Err(error)),
        }
    }

    fn validate_frame(&self, binding: &Binding, receipt: &Receipt) -> Result<()> {
        if self
            .owner
            .as_ref()
            .is_some_and(|owner| !Arc::ptr_eq(owner, &binding.owner))
        {
            return Err(Error::Conflict("delivery owner changed"));
        }
        if receipt
            .deadline
            .is_some_and(|deadline| Instant::now() >= deadline)
        {
            return Err(Error::Conflict("delivery grant expired"));
        }
        if receipt.consumed {
            return Err(Error::Conflict("delivery already consumed"));
        }
        if binding.plan != self.plan {
            return Err(Error::Conflict("delivery plan changed"));
        }
        if binding.first != self.next {
            return Err(Error::Conflict("delivery interval changed"));
        }
        if self
            .session
            .as_ref()
            .is_some_and(|session| session != &binding.session)
        {
            return Err(Error::Conflict("delivery session changed"));
        }
        // Fail closed on a clock error as well as expiration.
        if let Some(validity) = &binding.validity
            && !validity.contains(&crate::provider_oauth::now()?)
        {
            return Err(Error::Denied);
        }
        Ok(())
    }

    // Authority::current keeps validation and payload transfer in one deciding
    // turn under its mutex; this helper must not be called before that turn.
    fn accept_current_frame<T>(
        &mut self,
        binding: &Binding,
        receipt: &mut Receipt,
        payload: &mut Option<T>,
    ) -> Result<T> {
        self.validate_frame(binding, receipt)?;
        let next = self
            .next
            .checked_add(binding.rows)
            .ok_or(Error::Invalid("delivery interval exhausted"))?;
        let value = payload
            .take()
            .ok_or(Error::Conflict("delivery payload absent"))?;
        self.next = next;
        self.owner.get_or_insert_with(|| binding.owner.clone());
        self.session.get_or_insert_with(|| binding.session.clone());
        receipt.consumed = true;
        #[cfg(feature = "commit-observer")]
        {
            receipt.accepted_at = Some(std::time::SystemTime::now());
        }
        binding.completion.changed.notify_all();
        Ok(value)
    }
}
impl Drop for DeliveryFrame {
    fn drop(&mut self) {
        if let Ok(mut receipt) = self.0.completion.state.lock() {
            if !receipt.consumed {
                receipt.rejected = true;
            }
            let producer = receipt.producer_waker.take();
            self.0.completion.changed.notify_all();
            drop(receipt);
            if let Some(waker) = producer {
                waker.wake();
            }
        }
    }
}
impl Ledger {
    /// Reauthorize this exact already-burned release. No range, hold or upstream
    /// request is created. The receiver cursor remains unchanged until handoff.
    pub fn refresh_provider_delivery(
        &mut self,
        permit: &ProviderDispatch,
        proof: &DeliveryProducer,
        format: &str,
    ) -> Result<()> {
        let binding = &proof.0;
        self.check_provider_session(permit)?;
        if binding.session != self.session
            || binding.plan != permit.digest
            || binding.format != format
        {
            return Err(Error::Conflict("foreign delivery owner"));
        }
        #[cfg(feature = "commit-observer")]
        {
            let mut receipt = binding
                .completion
                .state
                .lock()
                .map_err(|_| Error::Conflict("delivery poisoned"))?;
            receipt.refresh_count += 1;
        }
        let (mut tx, domains) =
            crate::provider::begin_snapshot_validation(&mut self.connection, permit)?;
        if tx.delivery_scope() != binding.scope {
            return Err(Error::Conflict(
                "delivery conflict roots changed; old receipt retired",
            ));
        }
        let first = binding
            .snapshot
            .manifest
            .first()
            .ok_or(Error::Conflict("snapshot absent"))?;
        let last = binding
            .snapshot
            .manifest
            .last()
            .ok_or(Error::Conflict("snapshot absent"))?;
        crate::provider::guard_live_range(
            &tx,
            permit,
            &domains,
            "emitProvider",
            first.first..last.first + last.rows,
            format,
        )?;
        for range in &binding.snapshot.manifest {
            require_release(&tx, permit, range)?;
        }
        tx.refresh_delivery_receipt(binding.snapshot.completion.clone());
        tx.commit_delivery_refresh().map_err(db)
    }
}
fn require_release(
    tx: &crate::persistence::WriteScope<'_>,
    permit: &ProviderDispatch,
    binding: &SnapshotRange,
) -> Result<()> {
    let digest: Option<String> = crate::persistence::maybe(tx,
        "SELECT digest FROM provider_releases WHERE family=?1 AND node=?2 AND sequence=?3 AND length=?4 AND state='released'",
        crate::persistence::params![permit.plan.family.clone(),permit.plan.node.clone(),binding.first as i64,binding.rows as i64], |row| row.get(0)).map_err(db)?;
    if digest.as_deref() != Some(binding.digest.as_str()) {
        return Err(Error::Conflict("delivery release absent"));
    }
    Ok(())
}

/// Test-host timings for the actual receipt/receiver boundary, never permission.
#[cfg(feature = "commit-observer")]
pub struct DeliveryObservation {
    pub first: u64,
    pub acknowledged_unix_nanos: u128,
    pub accepted_unix_nanos: u128,
    pub lock_wait_nanos: u128,
    pub turn_nanos: u128,
    pub refresh_count: u64,
}
#[cfg(feature = "commit-observer")]
impl DeliveryProducer {
    pub fn observation(&self) -> Option<DeliveryObservation> {
        let receipt = self.0.completion.state.lock().ok()?;
        Some(DeliveryObservation {
            first: self.0.first,
            acknowledged_unix_nanos: receipt
                .acknowledged_at?
                .duration_since(std::time::UNIX_EPOCH)
                .ok()?
                .as_nanos(),
            accepted_unix_nanos: receipt
                .accepted_at?
                .duration_since(std::time::UNIX_EPOCH)
                .ok()?
                .as_nanos(),
            lock_wait_nanos: receipt.lock_wait_nanos,
            turn_nanos: receipt.turn_nanos,
            refresh_count: receipt.refresh_count,
        })
    }
}
