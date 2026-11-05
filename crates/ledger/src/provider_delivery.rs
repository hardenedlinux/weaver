// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Inert gRPC frames join acknowledged Turso validation at the receiver owner.
use crate::{
    Ledger, ProviderDispatch, db,
    persistence::{authority::Completion, owner::Owner, scheduler::Scope},
};
use std::{
    sync::Arc,
    task::{Context, Poll},
    time::{Duration, Instant},
};
use weaver_contracts::{Error, ProviderPlan, Result};

struct Binding {
    owner: Arc<Owner>,
    completion: Arc<Completion>,
    scope: Scope,
    session: String,
    plan: String,
    format: String,
    digest: String,
    first: u64,
    rows: u64,
    expires: Option<u64>,
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
    pub(crate) fn new(
        owner: Arc<Owner>,
        completion: Arc<Completion>,
        scope: Scope,
        permit: &ProviderDispatch,
        release: &crate::ProviderRelease,
        format: &str,
    ) -> Self {
        Self(Arc::new(Binding {
            owner,
            completion,
            scope,
            session: permit.session.clone(),
            plan: permit.digest.clone(),
            format: format.to_owned(),
            digest: release.digest.clone(),
            first: release.sequence,
            rows: release.length,
            expires: permit.oauth_expires,
        }))
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
    pub fn acknowledge(&self, deadline: Instant) -> Result<()> {
        let mut receipt = self
            .0
            .completion
            .state
            .lock()
            .map_err(|_| Error::Conflict("delivery poisoned"))?;
        if receipt.rejected || receipt.stamp.is_none() {
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
        let mut receipt = self
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
            receipt.refresh = false;
            return Ok(Some(DeliveryWait::Refresh));
        }
        Ok(None)
    }
    /// No engine lock is retained across this bounded blocking producer wait.
    pub fn wait(&self, cancelled: impl Fn() -> bool, deadline: Instant) -> Result<DeliveryWait> {
        let completion = &self.0.completion;
        let mut receipt = completion
            .state
            .lock()
            .map_err(|_| Error::Conflict("delivery poisoned"))?;
        loop {
            if receipt.consumed {
                return Ok(DeliveryWait::Accepted);
            }
            if receipt.rejected || cancelled() || Instant::now() >= deadline {
                return Err(Error::Conflict("delivery cancelled or unavailable"));
            }
            if receipt.refresh {
                receipt.refresh = false;
                return Ok(DeliveryWait::Refresh);
            }
            (receipt, _) = completion
                .changed
                .wait_timeout(receipt, Duration::from_millis(5))
                .map_err(|_| Error::Conflict("delivery poisoned"))?;
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
            |receipt| {
                if self
                    .owner
                    .as_ref()
                    .is_some_and(|owner| !Arc::ptr_eq(owner, &binding.owner))
                    || receipt
                        .deadline
                        .is_some_and(|deadline| Instant::now() >= deadline)
                    || receipt.consumed
                    || binding.plan != self.plan
                    || binding.first != self.next
                    || self
                        .session
                        .as_ref()
                        .is_some_and(|session| session != &binding.session)
                {
                    return Err(Error::Conflict("delivery owner, interval or grant expired"));
                }
                // Fail closed on a clock error as well as expiration.
                if let Some(expires) = binding.expires
                    && crate::provider_oauth::now()? >= expires
                {
                    return Err(Error::Denied);
                }
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
            },
        );
        match result {
            Ok(Some(value)) => Poll::Ready(Ok(value)),
            Ok(None) => Poll::Pending,
            Err(error) => Poll::Ready(Err(error)),
        }
    }
}
impl Drop for DeliveryFrame {
    fn drop(&mut self) {
        if let Ok(mut receipt) = self.0.completion.state.lock() {
            if !receipt.consumed {
                receipt.rejected = true;
            }
            self.0.completion.changed.notify_all();
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
        let (mut tx, domains) = crate::provider::begin_provider_effect(
            &mut self.connection,
            permit,
            crate::persistence::ProviderScopePhase::RevalidateDelivery,
        )?;
        if tx.delivery_scope() != binding.scope {
            return Err(Error::Conflict(
                "delivery conflict roots changed; old receipt retired",
            ));
        }
        crate::provider::guard_live_range(
            &tx,
            permit,
            &domains,
            "emitProvider",
            binding.first..binding.first + binding.rows,
            format,
        )?;
        require_release(&tx, permit, binding)?;
        tx.refresh_delivery_receipt(binding.completion.clone());
        tx.commit_delivery_refresh().map_err(db)
    }
}
fn require_release(
    tx: &crate::persistence::WriteScope<'_>,
    permit: &ProviderDispatch,
    binding: &Binding,
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
