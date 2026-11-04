// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Local deciding-store settlement. Metering never dispatches provider work.
use crate::{
    Ledger,
    persistence::{self, WriteScope, driver},
    store::{db, integer},
};
use weaver_contracts::{Error, MeteringApplication, MeteringDeployment, MeteringReceipt, Result};

pub(crate) fn deployment(connection: &driver::Connection) -> Result<Option<MeteringDeployment>> {
    let record: Option<String> = persistence::maybe(
        connection,
        "SELECT record FROM metering_deployment WHERE singleton=1",
        (),
        |row| row.get(0),
    )
    .map_err(db)?;
    record
        .map(|record| weaver_contracts::decode(record.as_bytes()))
        .transpose()
}

pub(crate) fn compatible(
    tx: &WriteScope<'_>,
    budget: [&str; 2],
    history: [&str; 2],
    principal: Option<&str>,
) -> Result<bool> {
    let Some(config) = deployment(tx)? else {
        return Ok(true);
    };
    let members = persistence::read_all(
        tx,
        "SELECT json_extract(t.record,'$.principal') FROM execution_origins o
         JOIN tasks t ON t.family=o.canonical_family
         WHERE o.budget_root IN (?1,?2) OR o.history_root IN (?3,?4)",
        [budget[0], budget[1], history[0], history[1]],
        |row| row.get::<String>(0),
    )
    .map_err(db)?;
    let mut scopes = members
        .iter()
        .map(String::as_str)
        .chain(principal)
        .map(|principal| config.tenant_for(principal));
    Ok(scopes
        .next()
        .is_none_or(|scope| scopes.all(|member| member == scope)))
}

pub(crate) fn bind(tx: &WriteScope<'_>, family: &str, node: &str) -> Result<()> {
    let Some(config) = deployment(tx)? else {
        return Ok(());
    };
    let principal: String = persistence::one(
        tx,
        "SELECT json_extract(record,'$.principal') FROM tasks WHERE family=?1",
        [family],
        |row| row.get(0),
    )
    .map_err(db)?;
    if let Some(tenant) = config.tenant_for(&principal) {
        persistence::exec(
            tx,
            "INSERT INTO metering_reservations VALUES(?1,?2,?3,?4,?5)",
            [
                family,
                node,
                tenant,
                config.tenants[tenant].formula_digest()?.as_str(),
                config.authority_digest(tenant)?.as_str(),
            ],
        )
        .map_err(db)?;
    }
    Ok(())
}

fn original(
    tx: &WriteScope<'_>,
    config: &MeteringDeployment,
    receipt: &MeteringReceipt,
) -> Result<u64> {
    let ceiling = persistence::maybe(
        tx,
        "SELECT r.reserved FROM provider_runs r
         JOIN metering_reservations m ON (m.family,m.node)=(r.family,r.node)
         JOIN original_tasks o ON o.family=r.family
         WHERE r.family=?1 AND r.node=?2 AND r.digest=?3 AND r.target=?4
           AND r.state='complete' AND r.dispatched=2 AND o.origin=?5
           AND m.tenant=?6 AND m.formula_digest=?7 AND m.authority_digest=?8",
        [
            receipt.family.as_str(),
            &receipt.node,
            &receipt.plan_digest,
            &receipt.target,
            &receipt.origin,
            &receipt.tenant,
            &receipt.formula_digest,
            &config.authority_digest(&receipt.tenant)?,
        ],
        |row| integer(row, 0),
    )
    .map_err(db)?
    .ok_or(Error::Denied)?;
    let charged = weaver_policy::verify_metering(config, receipt)?;
    if charged > ceiling {
        return Err(Error::Denied);
    }
    Ok(ceiling - charged)
}

pub(crate) fn applied_release(tx: &WriteScope<'_>, family: &str) -> Result<u64> {
    let rows = persistence::read_all(tx,
        "SELECT tenant,application,node,receipt,released FROM metering_applications WHERE family=?1",
        [family], |row| Ok((row.get::<String>(0)?,row.get::<String>(1)?,
            row.get::<String>(2)?,row.get::<String>(3)?,integer(row,4)?))).map_err(db)?;
    if rows.is_empty() {
        return Ok(0);
    }
    let config = deployment(tx)?.ok_or(Error::Denied)?;
    rows.into_iter()
        .try_fold(0u64, |sum, (tenant, application, node, body, released)| {
            let evidence: MeteringReceipt = weaver_contracts::decode(body.as_bytes())?;
            if (
                evidence.family.as_str(),
                &evidence.tenant,
                &evidence.application,
                &evidence.node,
            ) != (family, &tenant, &application, &node)
                || original(tx, &config, &evidence)? != released
            {
                return Err(Error::Conflict("invalid metering projection"));
            }
            sum.checked_add(released)
                .ok_or(Error::Conflict("metering projection overflow"))
        })
}

impl Ledger {
    /// Trusted startup only. An existing store keeps its exact metering contract.
    pub fn install_metering(&mut self, config: &MeteringDeployment) -> Result<()> {
        config.validate()?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        match deployment(&tx)? {
            Some(previous) if previous != *config => {
                return Err(Error::Conflict(
                    "metering deployment differs from durable binding",
                ));
            }
            Some(_) => (),
            None => {
                let occupied = persistence::one(&tx,
                    "SELECT EXISTS(SELECT 1 FROM metering_reservations) OR EXISTS(SELECT 1 FROM metering_applications)",
                    (), |row| row.get::<bool>(0)).map_err(db)?;
                if occupied {
                    return Err(Error::Conflict(
                        "metering deployment missing from recovery image",
                    ));
                }
                persistence::exec(
                    &tx,
                    "INSERT INTO metering_deployment VALUES(1,?1)",
                    [serde_json::to_string(config)?],
                )
                .map_err(db)?;
            }
        }
        tx.commit().map_err(db)
    }

    pub fn apply_metering(&mut self, evidence: &MeteringReceipt) -> Result<MeteringApplication> {
        evidence.validate()?;
        // Origins are immutable. Reject absent or aliased families before taking
        // the family scope; the deciding transaction still verifies the full join.
        let original_family = crate::domains::view(&self.connection, &evidence.family)?;
        if original_family.canonical_family != evidence.family {
            return Err(Error::Denied);
        }
        let tx = persistence::begin_family(&mut self.connection, &evidence.family).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let config = deployment(&tx)?.ok_or(Error::Denied)?;
        let released = original(&tx, &config, evidence)?;
        crate::domains::require(&tx, &evidence.family)?;
        let body = serde_json::to_string(evidence)?;
        let existing: Option<String> = persistence::maybe(
            &tx,
            "SELECT receipt FROM metering_applications WHERE tenant=?1 AND application=?2",
            [evidence.tenant.as_str(), &evidence.application],
            |row| row.get(0),
        )
        .map_err(db)?;
        let result = MeteringApplication {
            application: evidence.application.clone(),
            charged: config.tenants[&evidence.tenant].charge(evidence.tokens)?,
            released,
        };
        if let Some(existing) = existing {
            return if existing == body {
                Ok(result)
            } else {
                Err(Error::Conflict("metering application already bound"))
            };
        }
        crate::publication_barrier::require_resolved(&tx)?;
        let domain = crate::domains::view(&tx, &evidence.family)?;
        let members = persistence::read_all(&tx,
            "SELECT json_extract(t.record,'$.principal') FROM execution_origins o
             JOIN tasks t ON t.family=o.canonical_family WHERE o.budget_root=?1 OR o.history_root=?2",
            [domain.stamp.budget_root.as_str(), &domain.stamp.history_root], |row| row.get::<String>(0)).map_err(db)?;
        if members
            .iter()
            .any(|principal| config.tenant_for(principal) != Some(&evidence.tenant))
        {
            return Err(Error::Denied);
        }
        let inserted = persistence::exec(
            &tx,
            "INSERT INTO metering_applications VALUES(?1,?2,?3,?4,?5,?6) ON CONFLICT DO NOTHING",
            persistence::params![
                evidence.tenant.clone(),
                evidence.application.clone(),
                evidence.family.clone(),
                evidence.node.clone(),
                body,
                released as i64
            ],
        )
        .map_err(db)?;
        if inserted != 1 {
            return Err(Error::Conflict("original reservation already settled"));
        }
        let task = persistence::exec(
            &tx,
            "UPDATE tasks SET held=held-?1 WHERE family=?2 AND held>=?1",
            persistence::params![released as i64, evidence.family.clone()],
        )
        .map_err(db)?;
        let budget = persistence::exec(
            &tx,
            "UPDATE budget_domains SET held=held-?1 WHERE id=?2 AND root=id AND held>=?1",
            persistence::params![released as i64, domain.stamp.budget_root],
        )
        .map_err(db)?;
        if task != 1 || budget != 1 {
            return Err(Error::Conflict("metering balance changed"));
        }
        crate::domains::require(&tx, &evidence.family)?;
        tx.commit().map_err(db)?;
        Ok(result)
    }
}
