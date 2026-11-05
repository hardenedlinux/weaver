// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    persistence::{self, WriteScope},
    store::db,
};
use weaver_contracts::{DomainBinding, Error, Result, Task};

pub(crate) fn bind(
    tx: &WriteScope<'_>,
    task: &Task,
    requested: Option<&DomainBinding>,
) -> Result<()> {
    if let Ok(current) = super::view(tx, &task.family) {
        if current.canonical_family != task.family {
            return Err(Error::Conflict(
                "alias cannot register another original task",
            ));
        }
        if let Some(binding) = requested {
            let body: String = persistence::one(
                tx,
                "SELECT binding FROM execution_origins WHERE id=?1",
                [current.stamp.origin.as_str()],
                |r| r.get(0),
            )
            .map_err(db)?;
            if weaver_contracts::decode::<DomainBinding>(body.as_bytes())? != *binding {
                return Err(Error::Conflict("original domain binding is immutable"));
            }
        }
        return Ok(());
    }
    // Refuse partial recovery images rather than inventing an independent root.
    let retained:bool=persistence::one(tx,"SELECT EXISTS(SELECT 1 FROM tasks WHERE family=?1) OR EXISTS(SELECT 1 FROM family_origins WHERE family=?1)",[task.family.as_str()],|r|r.get(0)).map_err(db)?;
    if retained {
        return Err(Error::Conflict(
            "retained task lost authoritative domain binding",
        ));
    }
    let independent = DomainBinding {
        origin: task.family.clone(),
        budget: task.family.clone(),
        history: task.family.clone(),
        budget_limit: task.budget,
    };
    let binding = requested.unwrap_or(&independent);
    binding.validate()?;
    let original: Option<String> = persistence::maybe(
        tx,
        "SELECT canonical_family FROM execution_origins WHERE id=?1",
        [binding.origin.as_str()],
        |r| r.get(0),
    )
    .map_err(db)?;
    if original.is_some() {
        return Err(Error::Conflict(
            "origin already belongs to its original canonical family",
        ));
    }
    budget(tx, binding)?;
    persistence::exec(
        tx,
        "INSERT INTO history_domains VALUES(?1,?1,0,1) ON CONFLICT(id) DO NOTHING",
        [binding.history.as_str()],
    )
    .map_err(db)?;
    let budget: String = persistence::one(
        tx,
        "SELECT root FROM budget_domains WHERE id=?1",
        [binding.budget.as_str()],
        |r| r.get(0),
    )
    .map_err(db)?;
    let history: String = persistence::one(
        tx,
        "SELECT root FROM history_domains WHERE id=?1",
        [binding.history.as_str()],
        |r| r.get(0),
    )
    .map_err(db)?;
    if !crate::metering::compatible(tx, [&budget; 2], [&history; 2], Some(&task.principal))? {
        return Err(Error::Denied);
    }
    persistence::exec(
        tx,
        "INSERT INTO execution_origins VALUES(?1,?2,?3,?4,?5)",
        persistence::params![
            binding.origin.clone(),
            task.family.clone(),
            serde_json::to_string(binding)?,
            budget,
            history
        ],
    )
    .map_err(db)?;
    persistence::exec(
        tx,
        "INSERT INTO family_origins VALUES(?1,?2)",
        [task.family.as_str(), binding.origin.as_str()],
    )
    .map_err(db)?;
    Ok(())
}
fn budget(tx: &WriteScope<'_>, binding: &DomainBinding) -> Result<()> {
    persistence::exec(
        tx,
        "INSERT INTO budget_domains VALUES(?1,?1,?2,?2,0,1) ON CONFLICT(id) DO NOTHING",
        persistence::params![binding.budget.clone(), binding.budget_limit as i64],
    )
    .map_err(db)?;
    let declared: u64 = persistence::one(
        tx,
        "SELECT declared_limit FROM budget_domains WHERE id=?1",
        [binding.budget.as_str()],
        |r| crate::store::integer(r, 0),
    )
    .map_err(db)?;
    if declared != binding.budget_limit {
        return Err(Error::Conflict("shared domain limit cannot be replaced"));
    }
    Ok(())
}
impl crate::Ledger {
    /// Register an identity alias; it cannot own execution rows or replace an original.
    pub fn register_family_alias(
        &mut self,
        alias: &str,
        origin: &str,
    ) -> Result<weaver_contracts::DomainView> {
        weaver_contracts::identifier(alias)?;
        weaver_contracts::identifier(origin)?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let old: Option<String> = persistence::maybe(
            &tx,
            "SELECT origin FROM family_origins WHERE family=?1",
            [alias],
            |r| r.get(0),
        )
        .map_err(db)?;
        let retained: bool = persistence::one(
            &tx,
            "SELECT EXISTS(SELECT 1 FROM tasks WHERE family=?1)",
            [alias],
            |r| r.get(0),
        )
        .map_err(db)?;
        if old.is_none() && retained {
            return Err(Error::Conflict(
                "retained task lost authoritative domain binding",
            ));
        }
        if old.as_deref().is_some_and(|id| id != origin) {
            return Err(Error::Conflict("family origin binding is immutable"));
        }
        let _: String = persistence::one(
            &tx,
            "SELECT canonical_family FROM execution_origins WHERE id=?1",
            [origin],
            |r| r.get(0),
        )
        .map_err(db)?;
        persistence::exec(
            &tx,
            "INSERT INTO family_origins VALUES(?1,?2) ON CONFLICT(family) DO NOTHING",
            [alias, origin],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        super::view(&self.connection, alias)
    }
}
