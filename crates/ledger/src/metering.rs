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

pub(crate) fn bind(
    tx: &WriteScope<'_>,
    plan: &weaver_contracts::ProviderPlan,
    digest: &str,
    catalog_version: &str,
) -> Result<()> {
    let (family, node, ceiling) = (plan.family.as_str(), plan.node.as_str(), plan.ceiling);
    let current = crate::provider_catalog::current(tx)?;
    if current.as_ref().map_or("", |(version, _)| version.as_str()) != catalog_version {
        return Err(Error::Conflict("stale provider catalog"));
    }
    let Some(mut config) = deployment(tx)? else {
        return if catalog_version.is_empty() {
            Ok(())
        } else {
            Err(Error::Denied)
        };
    };
    if let Some((version, catalog)) = current {
        let entry = catalog.entries.get(digest).ok_or(Error::Denied)?;
        apply_catalog_entry(&mut config, digest, entry)?;
        persistence::exec(
            tx,
            "INSERT INTO provider_catalog_reservations VALUES(?1,?2,?3)",
            [family, node, version.as_str()],
        )
        .map_err(db)?;
    }
    let principal: String = persistence::one(
        tx,
        "SELECT json_extract(record,'$.principal') FROM tasks WHERE family=?1",
        [family],
        |row| row.get(0),
    )
    .map_err(db)?;
    if let Some(quote) = quote_digest(&config, plan, digest, &principal, catalog_version)? {
        let profile: String = persistence::one(
            tx,
            "SELECT record FROM provider_profiles WHERE id=?1",
            [plan.profile.as_str()],
            |row| row.get(0),
        )
        .map_err(db)?;
        let profile: weaver_contracts::ProviderProfile =
            weaver_contracts::decode(profile.as_bytes())?;
        if profile.request_facts(&plan.body)?.output_token_limit
            > config.provider_quotes[digest].token_bounds[3]
        {
            return Err(Error::Denied);
        }
        persistence::exec(
            tx,
            "INSERT INTO provider_rate_bindings VALUES(?1,?2,?3)",
            [family, node, &quote],
        )
        .map_err(db)?;
    }
    crate::provider_quota::reserve(tx, &config, family, node, &principal, ceiling)?;
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

fn apply_catalog_entry(
    config: &mut MeteringDeployment,
    digest: &str,
    entry: &weaver_contracts::CatalogEntry,
) -> Result<()> {
    let tenant = config
        .tenants
        .get_mut(&entry.quote.tenant)
        .ok_or(Error::Denied)?;
    tenant.rates = entry.user_rates;
    if tenant.formula_digest()? != entry.quote.formula_digest {
        return Err(Error::Conflict("retained formula digest mismatch"));
    }
    config.provider_quotes = [(digest.to_owned(), entry.quote.clone())].into();
    Ok(())
}

fn retained_catalog(tx: &WriteScope<'_>, family: &str, node: &str) -> Result<Option<String>> {
    persistence::maybe(
        tx,
        "SELECT catalog FROM provider_catalog_reservations WHERE family=?1 AND node=?2",
        [family, node],
        |row| row.get(0),
    )
    .map_err(db)
}

fn original(
    tx: &WriteScope<'_>,
    config: &MeteringDeployment,
    receipt: &MeteringReceipt,
) -> Result<MeteringApplication> {
    let snapshot;
    let config = if let Some(version) = retained_catalog(tx, &receipt.family, &receipt.node)? {
        let catalog = crate::provider_catalog::historical(tx, &version)?;
        let entry = catalog
            .entries
            .get(&receipt.plan_digest)
            .ok_or(Error::Denied)?;
        if entry.quote.tenant != receipt.tenant {
            return Err(Error::Denied);
        }
        let mut original = config.clone();
        apply_catalog_entry(&mut original, &receipt.plan_digest, entry)?;
        snapshot = original;
        &snapshot
    } else {
        config
    };
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
    match terminal_usage(tx, config, &receipt.family, &receipt.node)? {
        Some(expected)
            if expected.application == receipt.application
                && expected.tokens == receipt.tokens
                && expected.terminal_digest == receipt.terminal_digest => {}
        None if !config.require_terminal_usage => {}
        _ => return Err(Error::Denied),
    }
    let charged = weaver_policy::verify_metering(config, receipt)?;
    if charged > ceiling {
        return Err(Error::Denied);
    }
    Ok(MeteringApplication {
        application: receipt.application.clone(),
        charged,
        released: ceiling - charged,
    })
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
                || original(tx, &config, &evidence)?.released != released
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
        self.apply_metering_from(evidence, None)
    }

    pub fn apply_metering_from(
        &mut self,
        evidence: &MeteringReceipt,
        caller: Option<&weaver_contracts::SourceIdentity>,
    ) -> Result<MeteringApplication> {
        evidence.validate()?;
        // Origins are immutable. Reject absent or aliased families before taking
        // the family scope; the deciding transaction still verifies the full join.
        require_meter_family(&self.connection, &evidence.family)?;
        let tx = persistence::begin_family(&mut self.connection, &evidence.family).map_err(db)?;
        let config = authorize_metering_application(&tx, self.source.as_ref(), caller, evidence)?;
        let result = original(&tx, &config, evidence)?;
        crate::domains::require(&tx, &evidence.family)?;
        crate::provider_quota::require(&tx, &config, &evidence.family, &evidence.node)?;
        let body = serde_json::to_string(evidence)?;
        let existing: Option<String> = persistence::maybe(
            &tx,
            "SELECT receipt FROM metering_applications WHERE tenant=?1 AND application=?2",
            [evidence.tenant.as_str(), &evidence.application],
            |row| row.get(0),
        )
        .map_err(db)?;
        if let Some(existing) = existing {
            return if existing == body {
                Ok(result)
            } else {
                Err(Error::Conflict("metering application already bound"))
            };
        }
        apply_new_metering_application(&tx, &config, evidence, body, result.released)?;
        tx.commit().map_err(db)?;
        Ok(result)
    }
}

fn authorize_metering_application(
    tx: &persistence::WriteScope<'_>,
    source: Option<&weaver_contracts::SourceIdentity>,
    caller: Option<&weaver_contracts::SourceIdentity>,
    evidence: &MeteringReceipt,
) -> Result<MeteringDeployment> {
    crate::source_authority::require(tx, source)?;
    let config = deployment(tx)?.ok_or(Error::Denied)?;
    if let Some(caller) = caller {
        crate::metering_credentials::require(
            tx,
            &config,
            caller,
            &evidence.tenant,
            &evidence.issuer,
        )?;
    }
    Ok(config)
}

fn apply_new_metering_application(
    tx: &persistence::WriteScope<'_>,
    config: &MeteringDeployment,
    evidence: &MeteringReceipt,
    body: String,
    released: u64,
) -> Result<()> {
    crate::publication_barrier::require_resolved(tx)?;
    let domain = crate::domains::view(tx, &evidence.family)?;
    let members = persistence::read_all(
        tx,
        "SELECT json_extract(t.record,'$.principal') FROM execution_origins o
         JOIN tasks t ON t.family=o.canonical_family WHERE o.budget_root=?1 OR o.history_root=?2",
        [
            domain.stamp.budget_root.as_str(),
            &domain.stamp.history_root,
        ],
        |row| row.get::<String>(0),
    )
    .map_err(db)?;
    if members
        .iter()
        .any(|principal| config.tenant_for(principal) != Some(&evidence.tenant))
    {
        return Err(Error::Denied);
    }
    let inserted = persistence::exec(
        tx,
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
        tx,
        "UPDATE tasks SET held=held-?1 WHERE family=?2 AND held>=?1",
        persistence::params![released as i64, evidence.family.clone()],
    )
    .map_err(db)?;
    let budget = persistence::exec(
        tx,
        "UPDATE budget_domains SET held=held-?1 WHERE id=?2 AND root=id AND held>=?1",
        persistence::params![released as i64, domain.stamp.budget_root],
    )
    .map_err(db)?;
    if task != 1 || budget != 1 {
        return Err(Error::Conflict("metering balance changed"));
    }
    crate::provider_quota::release(tx, &evidence.family, &evidence.node, released)?;
    crate::provider_quota::require(tx, config, &evidence.family, &evidence.node)?;
    crate::domains::require(tx, &evidence.family)?;
    Ok(())
}

fn quote_digest(
    config: &MeteringDeployment,
    plan: &weaver_contracts::ProviderPlan,
    digest: &str,
    principal: &str,
    version: &str,
) -> Result<Option<String>> {
    if config.provider_quotes.is_empty() {
        return Ok(None);
    }
    let quote = config.provider_quotes.get(digest).ok_or(Error::Denied)?;
    let tenant = config.tenant_for(principal).ok_or(Error::Denied)?;
    if quote.tenant != tenant || config.tenants[tenant].charge(quote.token_bounds)? > plan.ceiling {
        return Err(Error::Denied);
    }
    let encoded = if version.is_empty() {
        serde_json::to_string(&("weaver.provider-rate-quote.v1", digest, quote))?
    } else {
        serde_json::to_string(&("weaver.provider-rate-quote.v2", version, digest, quote))?
    };
    Ok(Some(weaver_contracts::body_digest(&encoded)))
}

pub(crate) fn require_quote(
    tx: &WriteScope<'_>,
    config: &MeteringDeployment,
    plan: &weaver_contracts::ProviderPlan,
    digest: &str,
) -> Result<()> {
    let version = retained_catalog(tx, &plan.family, &plan.node)?;
    let historical;
    let config = if let Some(version) = &version {
        let catalog = crate::provider_catalog::historical(tx, version)?;
        let entry = catalog.entries.get(digest).ok_or(Error::Denied)?;
        let mut snapshot = config.clone();
        apply_catalog_entry(&mut snapshot, digest, entry)?;
        historical = snapshot;
        &historical
    } else {
        config
    };
    let principal: String = persistence::one(
        tx,
        "SELECT json_extract(record,'$.principal') FROM tasks WHERE family=?1",
        [plan.family.as_str()],
        |row| row.get(0),
    )
    .map_err(db)?;
    let expected = quote_digest(
        config,
        plan,
        digest,
        &principal,
        version.as_deref().unwrap_or_default(),
    )?;
    let retained: Option<String> = persistence::maybe(
        tx,
        "SELECT quote_digest FROM provider_rate_bindings WHERE family=?1 AND node=?2",
        [plan.family.as_str(), plan.node.as_str()],
        |row| row.get(0),
    )
    .map_err(db)?;
    if expected != retained {
        return Err(Error::Conflict("provider rate binding changed"));
    }
    Ok(())
}

pub(crate) fn require_task_quotes(
    tx: &WriteScope<'_>,
    task: &weaver_contracts::Task,
) -> Result<()> {
    let Some(config) = deployment(tx)? else {
        return Ok(());
    };
    if task.stream_contracts.is_empty() {
        return Ok(());
    }
    if let Some((_, catalog)) = crate::provider_catalog::current(tx)? {
        let tenant = config.tenant_for(&task.principal).ok_or(Error::Denied)?;
        for digest in task.stream_contracts.values() {
            if catalog
                .entries
                .get(digest)
                .is_none_or(|entry| entry.quote.tenant != tenant)
            {
                return Err(Error::Denied);
            }
        }
        return Ok(());
    }
    if config.provider_quotes.is_empty() {
        return Ok(());
    }
    let tenant = config.tenant_for(&task.principal).ok_or(Error::Denied)?;
    for digest in task.stream_contracts.values() {
        if config
            .provider_quotes
            .get(digest)
            .is_none_or(|quote| quote.tenant != tenant)
        {
            return Err(Error::Denied);
        }
    }
    Ok(())
}

fn terminal_usage(
    connection: &driver::Connection,
    config: &MeteringDeployment,
    family: &str,
    node: &str,
) -> Result<Option<MeteringReceipt>> {
    let record = persistence::maybe(
        connection,
        "SELECT m.tenant,o.origin,r.digest,r.target,m.formula_digest,u.tokens,c.catalog
         FROM provider_terminal_usage u
         JOIN provider_runs r ON (r.family,r.node)=(u.family,u.node)
         JOIN metering_reservations m ON (m.family,m.node)=(u.family,u.node)
         JOIN original_tasks o ON o.family=u.family
         LEFT JOIN provider_catalog_reservations c ON (c.family,c.node)=(u.family,u.node)
         WHERE u.family=?1 AND u.node=?2 AND r.state='complete' AND r.dispatched=2",
        [family, node],
        |row| {
            Ok((
                row.get::<String>(0)?,
                row.get::<String>(1)?,
                row.get::<String>(2)?,
                row.get::<String>(3)?,
                row.get::<String>(4)?,
                row.get::<String>(5)?,
                row.get::<Option<String>>(6)?,
            ))
        },
    )
    .map_err(db)?;
    let Some((tenant, origin, plan_digest, target, formula_digest, raw, catalog)) = record else {
        return Ok(None);
    };
    let tokens = weaver_contracts::decode(raw.as_bytes())?;
    let rule = config.tenants.get(&tenant).ok_or(Error::Denied)?;
    let terminal_digest = weaver_contracts::body_digest(&serde_json::to_string(&(
        "weaver.provider-usage-observation.v1",
        &config.audience,
        &tenant,
        family,
        node,
        &origin,
        &plan_digest,
        &target,
        &formula_digest,
        catalog,
        tokens,
    ))?);
    Ok(Some(MeteringReceipt {
        audience: config.audience.clone(),
        tenant,
        issuer: rule.issuer.clone(),
        application: terminal_digest.clone(),
        family: family.to_owned(),
        node: node.to_owned(),
        origin,
        plan_digest,
        target,
        formula_digest,
        terminal_digest,
        tokens,
        signature: String::new(),
    }))
}

impl Ledger {
    pub fn inspect_terminal_usage(
        &mut self,
        caller: &weaver_contracts::SourceIdentity,
        family: &str,
        node: &str,
    ) -> Result<MeteringReceipt> {
        require_meter_family(&self.connection, family)?;
        let tx = persistence::begin_family(&mut self.connection, family).map_err(db)?;
        let config = deployment(&tx)?.ok_or(Error::Denied)?;
        let record = terminal_usage(&tx, &config, family, node)?.ok_or(Error::Denied)?;
        crate::metering_credentials::require(&tx, &config, caller, &record.tenant, &record.issuer)?;
        Ok(record)
    }
}

fn require_meter_family(connection: &driver::Connection, family: &str) -> Result<()> {
    match crate::domains::view(connection, family) {
        Ok(view) if view.canonical_family == family => Ok(()),
        Ok(_) | Err(Error::Conflict(_)) => Err(Error::Denied),
        Err(error) => Err(error),
    }
}
