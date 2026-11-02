use crate::{
    persistence::{self, WriteScope},
    store::{db, integer},
};
use weaver_contracts::{Error, Result};

pub(crate) fn require(tx: &WriteScope<'_>, family: &str) -> Result<()> {
    let current = super::view(tx, family)?;
    if current.canonical_family != family {
        return Err(Error::Conflict("alias has no independent original claim"));
    }
    let rows=persistence::read_all(tx,"SELECT o.canonical_family,t.held FROM execution_origins o LEFT JOIN tasks t ON t.family=o.canonical_family WHERE o.budget_root=?1",[current.stamp.budget_root.as_str()],|r|Ok((r.get::<String>(0)?,integer(r,1)?))).map_err(db)?;
    let mut held = 0u64;
    let mut checked = std::collections::BTreeSet::new();
    for (member, amount) in rows {
        crate::exposure_manifest::require(tx, &member)?;
        checked.insert(member);
        held = held
            .checked_add(amount)
            .ok_or(Error::Conflict("domain exposure overflow"))?;
    }
    if held != current.held || held > current.budget_limit {
        return Err(Error::Conflict(
            "shared original exposure missing or inconsistent",
        ));
    }
    let count:u64=persistence::one(tx,"SELECT COUNT(*) FROM domain_history e JOIN execution_origins o ON o.id=e.origin WHERE o.history_root=?1",[current.stamp.history_root.as_str()],|r|integer(r,0)).map_err(db)?;
    if count != current.history_count {
        return Err(Error::Conflict(
            "original domain history missing or inconsistent",
        ));
    }
    let origins = persistence::read_all(
        tx,
        "SELECT id,canonical_family FROM execution_origins WHERE history_root=?1",
        [current.stamp.history_root.as_str()],
        |r| Ok((r.get::<String>(0)?, r.get::<String>(1)?)),
    )
    .map_err(db)?;
    let mut expected = std::collections::BTreeMap::new();
    for (origin, member) in origins {
        if !checked.contains(&member) {
            crate::exposure_manifest::require(tx, &member)?;
        }
        let claims = persistence::read_all(
            tx,
            "SELECT node,kind,reservations FROM execution_claims WHERE family=?1",
            [member.as_str()],
            |r| {
                Ok((
                    r.get::<String>(0)?,
                    r.get::<String>(1)?,
                    r.get::<String>(2)?,
                ))
            },
        )
        .map_err(db)?;
        for (node, kind, body) in claims {
            let reservations: crate::exposure_manifest::Members = serde_json::from_str(&body)?;
            for (id, reservation) in reservations {
                expected.insert(
                    (origin.clone(), node.clone(), id, kind.clone()),
                    reservation.digest,
                );
            }
        }
    }
    let observed=persistence::read_all(tx,"SELECT e.origin,e.node,e.member,e.event,e.digest FROM domain_history e JOIN execution_origins o ON o.id=e.origin WHERE o.history_root=?1",[current.stamp.history_root.as_str()],|r|Ok(((r.get::<String>(0)?,r.get::<String>(1)?,r.get::<String>(2)?,r.get::<String>(3)?),r.get::<String>(4)?))).map_err(db)?.into_iter().collect::<std::collections::BTreeMap<_,_>>();
    if expected != observed {
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
