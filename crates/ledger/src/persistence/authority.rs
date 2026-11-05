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
    global: u64,
    domains: [BTreeMap<String, u64>; 6],
    pending: BTreeMap<u64, Mutation>,
    failed: bool,
    waiters: Vec<Waker>,
}
struct Mutation {
    scope: Scope,
    invalidates: bool,
    external: BTreeMap<String, bool>,
    orphaned: bool,
}
#[derive(Default)]
pub(crate) struct Completion {
    pub state: Mutex<Receipt>,
    pub changed: Condvar,
}
#[derive(Default)]
pub(crate) struct Receipt {
    pub stamp: Option<Stamp>,
    pub acknowledged: bool,
    pub refresh: bool,
    pub consumed: bool,
    pub rejected: bool,
    pub waker: Option<Waker>,
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
            global: self.global,
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
    fn advance(&mut self, scope: &Scope) -> driver::Result<()> {
        match scope {
            Scope::All => {
                self.global = self
                    .global
                    .checked_add(1)
                    .ok_or_else(|| error("authority revision exhausted"))?
            }
            Scope::Domains(keys) => {
                for i in 0..6 {
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
        self.failed
            || self
                .pending
                .values()
                .any(|entry| entry.invalidates && entry.scope.overlaps(scope))
    }
}
impl Authority {
    pub(super) fn close(&self, scope: Scope) -> driver::Result<Close<'_>> {
        self.close_kind(scope, true)
    }
    pub(super) fn close_progress(
        &self,
        scope: Scope,
        proof: &crate::provider::RangeProgress,
    ) -> driver::Result<Close<'_>> {
        self.close_kind(scope, proof.invalidates())
    }
    fn close_kind(&self, scope: Scope, invalidates: bool) -> driver::Result<Close<'_>> {
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
                invalidates,
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
        if receipt.stamp.as_ref() != Some(&state.stamp(scope)) {
            receipt.refresh = true;
            completion.changed.notify_all();
            return Ok(None);
        }
        let accepted = accept(&mut receipt);
        #[cfg(any(test, feature = "commit-observer"))]
        if accepted.is_ok() {
            receipt.lock_wait_nanos = entered.duration_since(arrived).as_nanos();
            receipt.turn_nanos = entered.elapsed().as_nanos();
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
        if !mutation.invalidates {
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
        if modified && mutation.invalidates && state.advance(&self.scope).is_err() {
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
            if committed && known && !state.failed {
                receipt.stamp = Some(state.stamp(&self.scope));
            } else {
                receipt.rejected = true;
            }
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
