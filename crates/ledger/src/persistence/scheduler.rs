// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! FIFO read-set custody with exclusive original-origin provider writes.
use super::{driver, owner::error};
use std::{
    collections::VecDeque,
    sync::{Condvar, Mutex},
    time::Duration,
};

#[derive(Clone, PartialEq, Eq)]
pub(crate) enum Scope {
    All,
    // Distinct namespaces bind origin, budget, history, API key, user and tenant.
    Domains(super::scope_keys::Roots),
}

impl Scope {
    pub(super) fn overlaps(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Domains(left), Self::Domains(right)) => left.overlaps(right),
            _ => true,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Access {
    Exclusive,
    OriginWrite,
}

struct Ticket {
    access: Access,
    id: u64,
    scope: Scope,
}

impl Ticket {
    fn conflicts(&self, other: &Self) -> bool {
        match (&self.scope, &other.scope, self.access, other.access) {
            (Scope::Domains(a), Scope::Domains(b), Access::OriginWrite, Access::OriginWrite) => {
                a.key(0) == b.key(0)
            }
            _ => self.scope.overlaps(&other.scope),
        }
    }
}

#[derive(Default)]
pub(super) struct Scheduler {
    state: Mutex<State>,
    changed: Condvar,
}

#[derive(Default)]
struct State {
    waiting: VecDeque<Ticket>,
    active: Vec<Ticket>,
    generation: u64,
    ordinal: u64,
}

impl State {
    fn event(&mut self) -> u64 {
        self.ordinal += 1;
        self.ordinal
    }

    fn eligible(&self, at: usize) -> bool {
        let candidate = &self.waiting[at];
        self.waiting
            .iter()
            .take(at)
            .chain(&self.active)
            .all(|older| !older.conflicts(candidate))
    }
}

pub(super) struct Grant<'a> {
    scheduler: &'a Scheduler,
    id: u64,
    global: bool,
    pub generation: u64,
    #[cfg(feature = "commit-observer")]
    pub arrival: u64,
    #[cfg(feature = "commit-observer")]
    pub origin_write: bool,
    #[cfg(feature = "commit-observer")]
    pub granted: u64,
}

impl Scheduler {
    pub fn generation(&self) -> driver::Result<u64> {
        Ok(self.state.lock().map_err(error)?.generation)
    }

    pub fn acquire(
        &self,
        scope: Scope,
        cancelled: Option<&(dyn Fn() -> bool + Send + Sync)>,
    ) -> driver::Result<Grant<'_>> {
        self.acquire_access(scope, Access::Exclusive, cancelled)
    }

    /// Only sealed provider progress/lifecycle callers can select this lease.
    /// It still reads all six namespaces; only its origin is writable.
    pub fn acquire_origin(
        &self,
        scope: Scope,
        cancelled: Option<&(dyn Fn() -> bool + Send + Sync)>,
    ) -> driver::Result<Grant<'_>> {
        self.acquire_access(scope, Access::OriginWrite, cancelled)
    }

    fn acquire_access(
        &self,
        scope: Scope,
        access: Access,
        cancelled: Option<&(dyn Fn() -> bool + Send + Sync)>,
    ) -> driver::Result<Grant<'_>> {
        let mut state = self.state.lock().map_err(error)?;
        let ticket = state.event();
        let global = matches!(scope, Scope::All);
        state.waiting.push_back(Ticket {
            id: ticket,
            scope,
            access,
        });
        loop {
            let position = state
                .waiting
                .iter()
                .position(|entry| entry.id == ticket)
                .ok_or_else(|| error("scheduler ticket disappeared"))?;
            if cancelled.is_some_and(|check| check()) {
                state.waiting.remove(position);
                self.changed.notify_all();
                return Err(error("provider range cancelled before scheduler grant"));
            }
            if state.eligible(position) {
                let entry = state
                    .waiting
                    .remove(position)
                    .ok_or_else(|| error("scheduler ticket disappeared"))?;
                state.active.push(entry);
                return Ok(Grant {
                    scheduler: self,
                    id: ticket,
                    global,
                    generation: state.generation,
                    #[cfg(feature = "commit-observer")]
                    arrival: ticket,
                    #[cfg(feature = "commit-observer")]
                    origin_write: access == Access::OriginWrite && !global,
                    #[cfg(feature = "commit-observer")]
                    granted: state.event(),
                });
            }
            state = if cancelled.is_some() {
                self.changed
                    .wait_timeout(state, Duration::from_millis(5))
                    .map_err(error)?
                    .0
            } else {
                self.changed.wait(state).map_err(error)?
            };
        }
    }
}

impl Grant<'_> {
    pub fn matches_domains(&self, keys: &super::scope_keys::Roots) -> driver::Result<bool> {
        let state = self.scheduler.state.lock().map_err(error)?;
        Ok(state.active.iter().any(|ticket| {
            ticket.id == self.id
                && matches!(&ticket.scope, Scope::Domains(current) if current == keys)
        }))
    }
}

impl Drop for Grant<'_> {
    fn drop(&mut self) {
        let mut state = self
            .scheduler
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        state.active.retain(|ticket| ticket.id != self.id);
        if self.global {
            state.generation += 1;
        }
        self.scheduler.changed.notify_all();
    }
}

#[cfg(test)]
#[path = "../../tests/unit/persistence_scheduler.rs"]
mod tests;
