// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authority-owned origin and budget/history roots. Adapters never choose lock keys.
use crate::{
    persistence::{self, WriteScope, driver},
    store::{db, integer},
};
use weaver_contracts::{DomainStamp, DomainView, Error, Result};

const DOMAIN_VIEW: &str = "SELECT o.id,o.canonical_family,o.budget_root,o.history_root,b.epoch,h.epoch,b.ceiling,b.held,h.events,registration.task_key FROM family_origins f JOIN execution_origins o ON o.id=f.origin JOIN original_tasks registration ON registration.origin=o.id AND registration.family=o.canonical_family JOIN budget_domains b ON b.id=o.budget_root AND b.root=b.id JOIN history_domains h ON h.id=o.history_root AND h.root=h.id JOIN budget_domains original_budget ON original_budget.id=json_extract(o.binding,'$.budget') AND original_budget.root=b.id AND original_budget.declared_limit=json_extract(o.binding,'$.budget_limit') JOIN history_domains original_history ON original_history.id=json_extract(o.binding,'$.history') AND original_history.root=h.id WHERE f.family=?1 AND json_extract(o.binding,'$.origin')=o.id";

pub(crate) fn view(connection: &driver::Connection, family: &str) -> Result<DomainView> {
    require_view(persistence::maybe_prepared(
        connection,
        DOMAIN_VIEW,
        [family],
        decode(family),
    ))
}

pub(crate) fn view_current(tx: &WriteScope<'_>, family: &str) -> Result<DomainView> {
    require_view(persistence::maybe_current(
        tx,
        DOMAIN_VIEW,
        [family],
        decode(family),
    ))
}

#[cfg(feature = "commit-observer")]
thread_local! {
    static FRESH_PROVIDER_DOMAIN_PLAN: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Same-image diagnostic that recompiles the domain query in each scope.
#[cfg(feature = "commit-observer")]
pub fn use_fresh_provider_domain_plan(fresh: bool) {
    FRESH_PROVIDER_DOMAIN_PLAN.set(fresh);
}

pub(crate) fn warm_provider_domain_plan(connection: &driver::Connection) {
    #[cfg(feature = "commit-observer")]
    if FRESH_PROVIDER_DOMAIN_PLAN.get() {
        return;
    }
    // Turso caches the compatible SQL program, never an open cursor.
    // Admission still requires the deciding read if prewarming fails.
    let _ = futures_executor::block_on(connection.prepare_cached(DOMAIN_VIEW));
}

pub(crate) fn provider_view(tx: &WriteScope<'_>, family: &str) -> Result<DomainView> {
    #[cfg(feature = "commit-observer")]
    if FRESH_PROVIDER_DOMAIN_PLAN.get() {
        return view_current(tx, family);
    }
    require_view(persistence::maybe_prepared(
        tx,
        DOMAIN_VIEW,
        [family],
        decode(family),
    ))
}

fn require_view(view: driver::Result<Option<DomainView>>) -> Result<DomainView> {
    view.map_err(db)?
        .ok_or(Error::Conflict("authoritative execution domain missing"))
}

fn decode(family: &str) -> impl FnOnce(&persistence::Row) -> driver::Result<DomainView> + '_ {
    move |r| {
        Ok(DomainView {
            family: family.into(),
            canonical_family: r.get(1)?,
            stamp: DomainStamp {
                task_key: r.get(9)?,
                origin: r.get(0)?,
                budget_root: r.get(2)?,
                history_root: r.get(3)?,
                budget_epoch: integer(r, 4)?,
                history_epoch: integer(r, 5)?,
            },
            budget_limit: integer(r, 6)?,
            held: integer(r, 7)?,
            history_count: integer(r, 8)?,
        })
    }
}

pub(crate) fn stamp(tx: &WriteScope<'_>, family: &str) -> Result<DomainStamp> {
    let current = view(tx, family)?;
    if current.canonical_family != family {
        return Err(Error::Conflict(
            "family alias must recover original canonical task",
        ));
    }
    Ok(current.stamp)
}
pub(crate) fn require_stamp(
    tx: &WriteScope<'_>,
    family: &str,
    expected: &DomainStamp,
) -> Result<()> {
    if stamp(tx, family)? != *expected {
        return Err(Error::Conflict(
            "execution domain migrated; old permit fenced",
        ));
    }
    super::require(tx, family)
}
pub(crate) fn lock_keys(
    connection: &driver::Connection,
    family: &str,
) -> driver::Result<[String; 3]> {
    let current = view(connection, family).map_err(|e| driver::Error::Misuse(e.to_string()))?;
    if current.canonical_family != family {
        return Err(driver::Error::Misuse(
            "family alias is not another executable origin".into(),
        ));
    }
    Ok(stamp_keys(&current.stamp))
}
pub(crate) fn stamp_keys(stamp: &DomainStamp) -> [String; 3] {
    [
        stamp.origin.clone(),
        stamp.budget_root.clone(),
        stamp.history_root.clone(),
    ]
}
impl crate::Ledger {
    /// Observation only; subsequent effects rejoin these authoritative roots.
    pub fn execution_domains(&self, family: &str) -> Result<DomainView> {
        view(&self.connection, family)
    }
    /// Authenticated source registration; the binding and original task commit together.
    pub fn register_task_domains(
        &mut self,
        task: &weaver_contracts::Task,
        domains: &weaver_contracts::DomainBinding,
        publication: Option<&weaver_contracts::PublicationKey>,
    ) -> Result<()> {
        self.register_task_binding(task, publication, Some(domains))
    }
}
