// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    persistence::{self, WriteScope},
    store::{db, integer},
};
use weaver_contracts::{Error, Result};

pub(crate) fn require(tx: &WriteScope<'_>, family: &str) -> Result<()> {
    let current = super::view_current(tx, family)?;
    require_view(tx, &current)
}

/// Consume a view read in this same transaction before any intervening mutation.
pub(crate) fn require_view(
    tx: &WriteScope<'_>,
    current: &weaver_contracts::DomainView,
) -> Result<()> {
    if current.canonical_family != current.family {
        return Err(Error::Conflict("alias has no independent original claim"));
    }
    let rows=persistence::read_all_current(tx,"SELECT o.canonical_family,t.held FROM execution_origins o LEFT JOIN tasks t ON t.family=o.canonical_family WHERE o.budget_root=?1",[current.stamp.budget_root.as_str()],|r|Ok((r.get::<String>(0)?,integer(r,1)?))).map_err(db)?;
    let origins = persistence::read_all_current(
        tx,
        "SELECT id,canonical_family FROM execution_origins WHERE history_root=?1",
        [current.stamp.history_root.as_str()],
        |r| Ok((r.get::<String>(0)?, r.get::<String>(1)?)),
    )
    .map_err(db)?;
    let mut history_members: HistoryMembers = origins
        .into_iter()
        .map(|(origin, family)| (family, (origin, None)))
        .collect();
    let mut held = 0u64;
    for (member, amount) in rows {
        let verified = verified_family(tx, &member)?;
        if let Some((_, claims)) = history_members.get_mut(&member) {
            *claims = Some(verified);
        }
        held = held
            .checked_add(amount)
            .ok_or(Error::Conflict("domain exposure overflow"))?;
    }
    if held != current.held || held > current.budget_limit {
        return Err(Error::Conflict(
            "shared original exposure missing or inconsistent",
        ));
    }
    require_history(tx, current, history_members)
}

fn verified_family(tx: &WriteScope<'_>, family: &str) -> Result<crate::exposure_manifest::Family> {
    crate::task_origins::require(tx, family)?;
    crate::exposure_manifest::verified_members(tx, family)
}

type HistoryMembers =
    std::collections::BTreeMap<String, (String, Option<crate::exposure_manifest::Family>)>;

fn require_history(
    tx: &WriteScope<'_>,
    current: &weaver_contracts::DomainView,
    members: HistoryMembers,
) -> Result<()> {
    let mut expected = std::collections::BTreeMap::new();
    for (member, (origin, checked)) in members {
        let claims = match checked {
            Some(claims) => claims,
            None => verified_family(tx, &member)?,
        };
        for ((node, kind, id), reservation) in claims {
            expected.insert((origin.clone(), node, id, kind), reservation.digest);
        }
    }
    let observed=persistence::read_all_current(tx,"SELECT e.origin,e.node,e.member,e.event,e.digest FROM domain_history e JOIN execution_origins o ON o.id=e.origin WHERE o.history_root=?1",[current.stamp.history_root.as_str()],|r|Ok(((r.get::<String>(0)?,r.get::<String>(1)?,r.get::<String>(2)?,r.get::<String>(3)?),r.get::<String>(4)?))).map_err(db)?;
    if observed.len() as u64 != current.history_count {
        return Err(Error::Conflict(
            "original domain history missing or inconsistent",
        ));
    }
    if expected != observed.into_iter().collect() {
        return Err(Error::Conflict("history no longer covers original claims"));
    }
    Ok(())
}

pub(crate) fn charge(tx: &WriteScope<'_>, family: &str, amount: u64) -> Result<()> {
    let current = super::view(tx, family)?;
    let n = persistence::exec(
        tx,
        "UPDATE budget_domains SET held=held+?1 WHERE id=?2 AND root=id AND ?1<=ceiling-held",
        persistence::params![amount as i64, current.stamp.budget_root],
    )
    .map_err(db)?;
    if n != 1 {
        return Err(Error::Conflict("shared domain budget exhausted"));
    }
    Ok(())
}
pub(crate) fn history(
    tx: &WriteScope<'_>,
    family: &str,
    node: &str,
    member: &str,
    event: &str,
    digest: &str,
) -> Result<()> {
    let current = super::view(tx, family)?;
    persistence::exec(
        tx,
        "INSERT INTO domain_history VALUES(?1,?2,?3,?4,?5)",
        [current.stamp.origin.as_str(), node, member, event, digest],
    )
    .map_err(db)?;
    let changed=persistence::exec(tx,"UPDATE history_domains SET events=events+1 WHERE id=?1 AND root=id AND events<9223372036854775807",[current.stamp.history_root.as_str()]).map_err(db)?;
    if changed != 1 {
        return Err(Error::Conflict("history domain exhausted"));
    }
    Ok(())
}
