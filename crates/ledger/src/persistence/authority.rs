// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Close before every scoped write. No database or file I/O occurs in this mutex.
use super::{driver, owner::error, scheduler::Scope};
use std::{
    collections::BTreeMap,
    sync::{Arc, Condvar, Mutex},
    task::Waker,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Stamp {
    global: u64,
    domains: Option<[u64; 6]>,
}
#[derive(Default)]
pub(crate) struct Authority {
    state: Mutex<State>,
}
#[derive(Default)]
struct State {
    serial: u64,
    whole: u64,
    global: u64,
    domains: [BTreeMap<String, u64>; 6],
    pending: BTreeMap<u64, Mutation>,
    failed: bool,
    waiters: Vec<Waker>,
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum Impact {
    Full,
    Origin,
    Preserved,
}
struct Mutation {
    scope: Scope,
    impact: Impact,
    external: BTreeMap<String, bool>,
    orphaned: bool,
}
impl Mutation {
    fn affects(&self, reader: &Scope) -> bool {
        match (&self.scope, reader, self.impact) {
            (_, _, Impact::Preserved) => false,
            (Scope::Domains(writer), Scope::Domains(reader), Impact::Origin) => {
                writer.key(0) == reader.key(0)
            }
            _ => self.scope.overlaps(reader),
        }
    }
}
#[derive(Default)]
pub(crate) struct Completion {
    qualification: Arc<Mutex<Qualification>>,
    pub state: Mutex<Receipt>,
    pub changed: Condvar,
}
#[derive(Default)]
struct Qualification {
    stamp: Option<Stamp>,
    rejected: bool,
}
impl Completion {
    pub(crate) fn share_qualification(&self) -> Self {
        Self {
            qualification: self.qualification.clone(),
            state: Mutex::default(),
            changed: Condvar::default(),
        }
    }
    pub(crate) fn confirmed(&self) -> driver::Result<bool> {
        let qualification = self.qualification.lock().map_err(error)?;
        Ok(qualification.stamp.is_some() && !qualification.rejected)
    }
}
#[derive(Default)]
pub(crate) struct Receipt {
    pub acknowledged: bool,
    pub refresh: bool,
    pub consumed: bool,
    pub rejected: bool,
    pub waker: Option<Waker>,
    pub producer_waker: Option<Waker>,
    pub deadline: Option<std::time::Instant>,
    #[cfg(any(test, feature = "commit-observer"))]
    pub acknowledged_at: Option<std::time::SystemTime>,
    #[cfg(any(test, feature = "commit-observer"))]
    pub accepted_at: Option<std::time::SystemTime>,
    #[cfg(any(test, feature = "commit-observer"))]
    pub lock_wait_nanos: u128,
    #[cfg(any(test, feature = "commit-observer"))]
    pub turn_nanos: u128,
    #[cfg(any(test, feature = "commit-observer"))]
    pub refresh_count: u64,
}
pub(super) enum Outcome {
    Committed { modified: bool },
    Absent,
    Unknown,
}
pub(super) struct Close<'a> {
    authority: &'a Authority,
    id: u64,
    scope: Scope,
    receipt: Option<Arc<Completion>>,
    ended: bool,
    committing: bool,
}
impl State {
    fn stamp(&self, scope: &Scope) -> Stamp {
        Stamp {
            global: if matches!(scope, Scope::All) {
                self.whole
            } else {
                self.global
            },
            domains: match scope {
                Scope::All => None,
                Scope::Domains(keys) => Some(std::array::from_fn(|i| {
                    keys.key(i)
                        .and_then(|key| self.domains[i].get(key))
                        .copied()
                        .unwrap_or(0)
                })),
            },
        }
    }
    fn advance(&mut self, scope: &Scope, impact: Impact) -> driver::Result<()> {
        self.whole = self
            .whole
            .checked_add(1)
            .ok_or_else(|| error("whole-view revision exhausted"))?;
        match scope {
            Scope::All => {
                self.global = self
                    .global
                    .checked_add(1)
                    .ok_or_else(|| error("authority revision exhausted"))?
            }
            Scope::Domains(keys) => {
                for i in 0..if impact == Impact::Origin { 1 } else { 6 } {
                    if let Some(key) = keys.key(i) {
                        let value = self.domains[i].entry(key.to_owned()).or_default();
                        *value = value
                            .checked_add(1)
                            .ok_or_else(|| error("domain revision exhausted"))?;
                    }
                }
            }
        }
        Ok(())
    }
    fn closed(&self, scope: &Scope) -> bool {
        self.failed || self.pending.values().any(|entry| entry.affects(scope))
    }
}
impl Authority {
    pub(super) fn close(&self, scope: Scope) -> driver::Result<Close<'_>> {
        self.close_kind(scope, Impact::Full)
    }
    pub(super) fn close_progress(
        &self,
        scope: Scope,
        proof: &crate::provider::RangeProgress,
    ) -> driver::Result<Close<'_>> {
        self.close_kind(
            scope,
            if proof.invalidates() {
                Impact::Full
            } else {
                Impact::Preserved
            },
        )
    }
    pub(super) fn close_lifecycle(
        &self,
        scope: Scope,
        proof: &crate::provider::OriginLifecycle,
    ) -> driver::Result<Close<'_>> {
        let impact = if proof.origin_only() && matches!(scope, Scope::Domains(_)) {
            Impact::Origin
        } else {
            Impact::Full
        };
        self.close_kind(scope, impact)
    }
    fn close_kind(&self, scope: Scope, impact: Impact) -> driver::Result<Close<'_>> {
        let mut state = self.state.lock().map_err(error)?;
        if state.failed {
            return Err(error("authority sealed until owner recovery"));
        }
        state.serial = state
            .serial
            .checked_add(1)
            .ok_or_else(|| error("authority cut exhausted"))?;
        let id = state.serial;
        state.pending.insert(
            id,
            Mutation {
                scope: scope.clone(),
                impact,
                external: BTreeMap::new(),
                orphaned: false,
            },
        );
        Ok(Close {
            authority: self,
            id,
            scope,
            receipt: None,
            ended: false,
            committing: false,
        })
    }
    /// A receiver can request refresh again while a native read is in flight.
    /// Consume only unsatisfied demand at the actual cut, under publication's
    /// mutex; a stale boolean must not create another native transaction.
    pub(crate) fn take_refresh(
        &self,
        scope: &Scope,
        completion: &Completion,
    ) -> weaver_contracts::Result<bool> {
        let state = self
            .state
            .lock()
            .map_err(|_| weaver_contracts::Error::Conflict("authority poisoned"))?;
        let mut receipt = completion
            .state
            .lock()
            .map_err(|_| weaver_contracts::Error::Conflict("delivery poisoned"))?;
        if receipt.consumed {
            return Ok(false);
        }
        let qualification = completion
            .qualification
            .lock()
            .map_err(|_| weaver_contracts::Error::Conflict("snapshot poisoned"))?;
        if state.failed || receipt.rejected || qualification.rejected {
            return Err(weaver_contracts::Error::Conflict("snapshot sealed"));
        }
        // A visible semantic barrier will supersede this read. Its outcome
        // wakes the receiver, which requests the then-current cut again.
        let requested = receipt.refresh
            && !state.closed(scope)
            && qualification.stamp.as_ref() != Some(&state.stamp(scope));
        receipt.refresh = false;
        Ok(requested)
    }
    /// The caller constructs the returned Poll::Ready item inside this turn.
    pub(crate) fn current<T>(
        &self,
        scope: &Scope,
        completion: &Completion,
        waker: &Waker,
        accept: impl FnOnce(&mut Receipt) -> weaver_contracts::Result<T>,
    ) -> weaver_contracts::Result<Option<T>> {
        #[cfg(any(test, feature = "commit-observer"))]
        let arrived = std::time::Instant::now();
        let mut state = self
            .state
            .lock()
            .map_err(|_| weaver_contracts::Error::Conflict("authority poisoned"))?;
        #[cfg(any(test, feature = "commit-observer"))]
        let entered = std::time::Instant::now();
        let mut receipt = completion
            .state
            .lock()
            .map_err(|_| weaver_contracts::Error::Conflict("delivery poisoned"))?;
        receipt.waker = Some(waker.clone());
        if state.failed || receipt.rejected {
            return Err(weaver_contracts::Error::Conflict(
                "delivery authority sealed",
            ));
        }
        if state.closed(scope) || !receipt.acknowledged {
            if !state.waiters.iter().any(|old| old.will_wake(waker)) {
                state.waiters.push(waker.clone());
            }
            return Ok(None);
        }
        let qualification = completion
            .qualification
            .lock()
            .map_err(|_| weaver_contracts::Error::Conflict("snapshot poisoned"))?;
        if qualification.rejected {
            return Err(weaver_contracts::Error::Conflict(
                "snapshot commit unconfirmed",
            ));
        }
        if qualification.stamp.as_ref() != Some(&state.stamp(scope)) {
            if !state.waiters.iter().any(|old| old.will_wake(waker)) {
                state.waiters.push(waker.clone());
            }
            receipt.refresh = true;
            let producer = receipt.producer_waker.take();
            completion.changed.notify_all();
            drop(receipt);
            drop(state);
            if let Some(waker) = producer {
                waker.wake();
            }
            return Ok(None);
        }
        drop(qualification);
        let accepted = accept(&mut receipt);
        #[cfg(any(test, feature = "commit-observer"))]
        if accepted.is_ok() {
            receipt.lock_wait_nanos = entered.duration_since(arrived).as_nanos();
            receipt.turn_nanos = entered.elapsed().as_nanos();
        }
        let producer = if receipt.consumed {
            receipt.producer_waker.take()
        } else {
            None
        };
        drop(receipt);
        drop(state);
        if let Some(waker) = producer {
            waker.wake();
        }
        accepted.map(Some)
    }
}
impl Close<'_> {
    pub(crate) fn settle_drop(&mut self) {
        if !self.ended {
            let _ = self.finish(if self.committing {
                Outcome::Unknown
            } else {
                Outcome::Absent
            });
        }
    }

    pub(crate) fn committing(&mut self) {
        self.committing = true;
    }
    pub(crate) fn replace_receipt(&mut self, receipt: Arc<Completion>) {
        self.receipt = Some(receipt);
    }
    pub(crate) fn scope(&self) -> Scope {
        self.scope.clone()
    }

    pub(crate) fn receipt(&mut self) -> driver::Result<Arc<Completion>> {
        if self.receipt.is_some() {
            return Err(error("one delivery receipt per scope"));
        }
        if self
            .authority
            .state
            .lock()
            .map_err(error)?
            .pending
            .get(&self.id)
            .is_some_and(|entry| entry.impact == Impact::Origin)
        {
            return Err(error("origin lifecycle cannot issue a delivery receipt"));
        }
        let receipt = Arc::new(Completion::default());
        self.receipt = Some(receipt.clone());
        Ok(receipt)
    }
    pub(crate) fn external(&self, path: &str, reconciled: bool) -> driver::Result<()> {
        let mut state = self.authority.state.lock().map_err(error)?;
        let mutation = state
            .pending
            .get_mut(&self.id)
            .ok_or_else(|| error("authority cut absent"))?;
        if mutation.impact != Impact::Full {
            return Err(error("range progress cannot reconcile external authority"));
        }
        mutation.external.insert(path.to_owned(), reconciled);
        Ok(())
    }
    pub(super) fn finish(&mut self, outcome: Outcome) -> driver::Result<()> {
        let (modified, committed, known) = match outcome {
            Outcome::Committed { modified } => (modified, true, true),
            Outcome::Absent => (false, false, true),
            Outcome::Unknown => (false, false, false),
        };
        let mut state = self.authority.state.lock().map_err(error)?;
        let mutation = state
            .pending
            .remove(&self.id)
            .ok_or_else(|| error("authority cut absent"))?;
        if !known {
            state.failed = true;
        }
        if modified
            && mutation.impact != Impact::Preserved
            && state.advance(&self.scope, mutation.impact).is_err()
        {
            state.failed = true;
        }
        if committed && mutation.external.values().all(|complete| *complete) {
            let paths = &mutation.external;
            state.pending.retain(|_, old| {
                !(old.orphaned
                    && !old.external.is_empty()
                    && old
                        .external
                        .keys()
                        .all(|path| paths.get(path) == Some(&true)))
            });
        }
        if !mutation.external.is_empty()
            && (!committed || mutation.external.values().any(|complete| !complete))
        {
            state.pending.insert(
                self.id,
                Mutation {
                    orphaned: true,
                    ..mutation
                },
            );
        }
        if let Some(completion) = &self.receipt {
            let mut receipt = completion.state.lock().map_err(error)?;
            let mut qualification = completion.qualification.lock().map_err(error)?;
            if committed && known && !state.failed {
                qualification.stamp = Some(state.stamp(&self.scope));
            } else {
                qualification.rejected = true;
                receipt.rejected = true;
                if let Some(waker) = receipt.producer_waker.take() {
                    state.waiters.push(waker);
                }
            }
            drop(qualification);
            completion.changed.notify_all();
            if let Some(waker) = receipt.waker.take() {
                state.waiters.push(waker);
            }
        }
        self.ended = true;
        let waiters = std::mem::take(&mut state.waiters);
        drop(state);
        for waker in waiters {
            waker.wake();
        }
        Ok(())
    }
}
impl Drop for Close<'_> {
    fn drop(&mut self) {
        if !self.ended {
            // An unwound commit or failed cleanup has no authoritative absence proof.
            let _ = self.finish(if self.committing {
                Outcome::Unknown
            } else {
                Outcome::Absent
            });
        }
    }
}

#[cfg(test)]
#[path = "../../tests/unit/authority_footprint.rs"]
mod footprint_tests;
