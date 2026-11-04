// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    persistence::{self, WriteScope},
    store::{db, integer},
};
use weaver_contracts::{DomainMigration, DomainMigrationReceipt, Error, Result, body_digest};

struct Budget {
    root: String,
    cap: u64,
    held: u64,
    epoch: u64,
}
struct History {
    root: String,
    events: u64,
    epoch: u64,
}
fn budget(tx: &WriteScope<'_>, id: &str) -> Result<Budget> {
    persistence::one(
        tx,
        "SELECT root,ceiling,held,epoch FROM budget_domains WHERE id=?1",
        [id],
        |r| {
            Ok(Budget {
                root: r.get(0)?,
                cap: integer(r, 1)?,
                held: integer(r, 2)?,
                epoch: integer(r, 3)?,
            })
        },
    )
    .map_err(db)
}
fn history(tx: &WriteScope<'_>, id: &str) -> Result<History> {
    persistence::one(
        tx,
        "SELECT root,events,epoch FROM history_domains WHERE id=?1",
        [id],
        |r| {
            Ok(History {
                root: r.get(0)?,
                events: integer(r, 1)?,
                epoch: integer(r, 2)?,
            })
        },
    )
    .map_err(db)
}
impl crate::Ledger {
    /// Whole-domain union only. No family detachment, capacity increase or refund.
    pub fn migrate_execution_domains(
        &mut self,
        command: &DomainMigration,
    ) -> Result<DomainMigrationReceipt> {
        command.validate()?;
        let digest = body_digest(&serde_json::to_string(command)?);
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        if let Some((old, body)) = persistence::maybe(
            &tx,
            "SELECT digest,receipt FROM domain_migrations WHERE operation_id=?1",
            [command.operation_id.as_str()],
            |r| Ok((r.get::<String>(0)?, r.get::<String>(1)?)),
        )
        .map_err(db)?
        {
            if old != digest {
                return Err(Error::Conflict("migration identity already bound"));
            }
            let receipt: DomainMigrationReceipt = weaver_contracts::decode(body.as_bytes())?;
            if receipt.operation_id != command.operation_id || receipt.digest != digest {
                return Err(Error::Conflict("original migration receipt inconsistent"));
            }
            return Ok(receipt);
        }
        let receipt = decide(&tx, command, digest)?;
        persistence::exec(
            &tx,
            "INSERT INTO domain_migrations VALUES(?1,?2,?3)",
            [
                command.operation_id.as_str(),
                receipt.digest.as_str(),
                serde_json::to_string(&receipt)?.as_str(),
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(receipt)
    }
}
fn decide(
    tx: &WriteScope<'_>,
    c: &DomainMigration,
    digest: String,
) -> Result<DomainMigrationReceipt> {
    let a = budget(tx, &c.budget_from)?;
    let b = budget(tx, &c.budget_to)?;
    let x = history(tx, &c.history_from)?;
    let y = history(tx, &c.history_to)?;
    let mut receipt = DomainMigrationReceipt {
        operation_id: c.operation_id.clone(),
        digest,
        committed: false,
        budget_root: b.root.clone(),
        history_root: y.root.clone(),
        budget_epoch: b.epoch,
        history_epoch: y.epoch,
    };
    let current = a.root == c.budget_from
        && b.root == c.budget_to
        && x.root == c.history_from
        && y.root == c.history_to
        && a.epoch == c.budget_from_epoch
        && b.epoch == c.budget_to_epoch
        && x.epoch == c.history_from_epoch
        && y.epoch == c.history_to_epoch;
    if !current
        || !crate::metering::compatible(
            tx,
            [&c.budget_from, &c.budget_to],
            [&c.history_from, &c.history_to],
            None,
        )?
    {
        return Ok(receipt);
    }
    let held = if c.budget_from == c.budget_to {
        b.held
    } else {
        a.held
            .checked_add(b.held)
            .ok_or(Error::Conflict("merged exposure overflow"))?
    };
    let cap = a.cap.min(b.cap);
    if held > cap {
        return Ok(receipt);
    }
    // Verify every original held projection before changing any root or counter.
    let families=persistence::read_all(tx,"SELECT canonical_family FROM execution_origins WHERE budget_root IN (?1,?2) OR history_root IN (?3,?4)",[c.budget_from.as_str(),c.budget_to.as_str(),c.history_from.as_str(),c.history_to.as_str()],|r|r.get::<String>(0)).map_err(db)?;
    for family in &families {
        super::require(tx, family)?;
    }
    if c.budget_from != c.budget_to {
        receipt.budget_epoch = next(a.epoch, b.epoch)?;
        persistence::exec(
            tx,
            "UPDATE budget_domains SET root=?1 WHERE root=?2",
            [c.budget_to.as_str(), c.budget_from.as_str()],
        )
        .map_err(db)?;
        persistence::exec(
            tx,
            "UPDATE budget_domains SET held=0 WHERE id=?1",
            [c.budget_from.as_str()],
        )
        .map_err(db)?;
        persistence::exec(
            tx,
            "UPDATE budget_domains SET ceiling=?1,held=?2,epoch=?3 WHERE id=?4",
            persistence::params![
                cap as i64,
                held as i64,
                receipt.budget_epoch as i64,
                c.budget_to.clone()
            ],
        )
        .map_err(db)?;
        persistence::exec(
            tx,
            "UPDATE execution_origins SET budget_root=?1 WHERE budget_root=?2",
            [c.budget_to.as_str(), c.budget_from.as_str()],
        )
        .map_err(db)?;
    }
    if c.history_from != c.history_to {
        receipt.history_epoch = next(x.epoch, y.epoch)?;
        let count = x
            .events
            .checked_add(y.events)
            .filter(|n| *n <= weaver_contracts::MAX_CREDITS)
            .ok_or(Error::Conflict("merged history overflow"))?;
        persistence::exec(
            tx,
            "UPDATE history_domains SET root=?1 WHERE root=?2",
            [c.history_to.as_str(), c.history_from.as_str()],
        )
        .map_err(db)?;
        persistence::exec(
            tx,
            "UPDATE history_domains SET events=0 WHERE id=?1",
            [c.history_from.as_str()],
        )
        .map_err(db)?;
        persistence::exec(
            tx,
            "UPDATE history_domains SET events=?1,epoch=?2 WHERE id=?3",
            persistence::params![
                count as i64,
                receipt.history_epoch as i64,
                c.history_to.clone()
            ],
        )
        .map_err(db)?;
        persistence::exec(
            tx,
            "UPDATE execution_origins SET history_root=?1 WHERE history_root=?2",
            [c.history_to.as_str(), c.history_from.as_str()],
        )
        .map_err(db)?;
    }
    for family in &families {
        super::require(tx, family)?;
    }
    receipt.committed = true;
    Ok(receipt)
}
fn next(a: u64, b: u64) -> Result<u64> {
    a.max(b)
        .checked_add(1)
        .filter(|n| *n <= weaver_contracts::MAX_CREDITS)
        .ok_or(Error::Conflict("domain epoch exhausted"))
}
