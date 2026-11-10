// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Source-declared candidate custody; registration rejoins the exact deciding cut.
use crate::{
    Ledger,
    persistence::{self, driver::Connection},
    store::{db, integer},
};
use weaver_contracts::{
    Error, ProviderCatalog, ProviderOperationBinding, ProviderOperationScope, ProviderPlan,
    ProviderRoutingScope, Publication, PublicationOutcome, Result, Task,
};

/// A coherent read for bounded Scheme work, never a later registration permit.
#[derive(Clone)]
pub struct ProviderOperationCut {
    pub binding: ProviderOperationBinding,
    pub catalog_version: String,
    pub catalog: Option<ProviderCatalog>,
    pub revision: u64,
    pub fence: u64,
}

fn binding(
    connection: &Connection,
    family: &str,
    node: &str,
) -> Result<Option<ProviderOperationBinding>> {
    let row: Option<(String, String)> = persistence::maybe(
        connection,
        "SELECT digest,record FROM provider_operation_scopes WHERE family=?1 AND node=?2",
        [family, node],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .map_err(db)?;
    row.map(|(digest, record)| {
        if weaver_contracts::body_digest(&record) != digest {
            return Err(Error::Conflict("provider routing record mismatch"));
        }
        let bound: ProviderOperationBinding = weaver_contracts::decode(record.as_bytes())?;
        bound.scope.validate()?;
        if bound.scope.task().family != family || bound.scope.node() != node {
            return Err(Error::Conflict("provider routing identity mismatch"));
        }
        Ok(bound)
    })
    .transpose()
}

fn cut(connection: &Connection, bound: ProviderOperationBinding) -> Result<ProviderOperationCut> {
    let catalog_scope = matches!(&bound.scope, ProviderOperationScope::Catalog { .. });
    // A fixed task already belongs to its committed publication. A catalog
    // scope can register a new task, so its declaring source must still be current.
    if catalog_scope
        && crate::source_authority::current(connection)?.as_ref() != Some(&bound.authority)
    {
        return Err(Error::Denied);
    }
    let publication = bound.scope.publication();
    let receipt = crate::publication::lookup(
        connection,
        &publication.operation_id,
        &publication.digest()?,
    )?
    .filter(|receipt| receipt.outcome == PublicationOutcome::Committed)
    .ok_or(Error::Conflict("routing publication not committed"))?;
    let (revision, fence): (u64, u64) = persistence::one(
        connection,
        "SELECT revision,fence FROM authority WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, integer(r, 1)?)),
    )
    .map_err(db)?;
    if receipt.revision != Some(revision) || receipt.fence != Some(fence) {
        return Err(Error::Conflict("routing publication no longer current"));
    }
    let (catalog_version, catalog) = if catalog_scope {
        let (version, catalog) = crate::provider_catalog::current(connection)?
            .ok_or(Error::Conflict("provider catalog unavailable"))?;
        (version, Some(catalog))
    } else {
        (String::new(), None)
    };
    Ok(ProviderOperationCut {
        binding: bound,
        catalog_version,
        catalog,
        revision,
        fence,
    })
}

fn require_declared_publication(
    connection: &Connection,
    publication: &Publication,
    digest: &str,
) -> Result<()> {
    if let Some(receipt) =
        crate::publication::lookup(connection, &publication.operation_id, digest)?
    {
        return if receipt.outcome == PublicationOutcome::Rejected {
            Err(Error::Denied)
        } else {
            Ok(())
        };
    }
    let pending: Option<(String, String)> = persistence::maybe(
        connection,
        "SELECT digest,proposal FROM authority_pending WHERE operation_id=?1",
        [publication.operation_id.as_str()],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .map_err(db)?;
    let (staged, record) = pending.ok_or(Error::Conflict("routing publication not staged"))?;
    let original: Publication = weaver_contracts::decode(record.as_bytes())?;
    if staged != digest || original != *publication {
        return Err(Error::Denied);
    }
    Ok(())
}

fn require_routed_cut(
    connection: &Connection,
    observed: &ProviderOperationCut,
    family: &str,
    node: &str,
    digest: &str,
) -> Result<()> {
    let original = binding(connection, family, node)?.ok_or(Error::Denied)?;
    if original != observed.binding {
        return Err(Error::Denied);
    }
    let current = cut(connection, original)?;
    if current.catalog != observed.catalog
        || current
            .catalog
            .as_ref()
            .is_none_or(|catalog| !catalog.entries.contains_key(digest))
    {
        return Err(Error::Denied);
    }
    if current.catalog_version != observed.catalog_version
        || current.revision != observed.revision
        || current.fence != observed.fence
    {
        return Err(Error::Conflict("provider routing cut changed"));
    }
    Ok(())
}

impl Ledger {
    /// Explicit authenticated-source declaration. An operation credential cannot
    /// create or replace this scope. Replays preserve its exact source epoch.
    pub fn register_provider_routing(&mut self, scope: &ProviderRoutingScope) -> Result<()> {
        self.register_provider_source(&ProviderOperationScope::Catalog {
            routing: scope.clone(),
        })
    }
    pub fn register_provider_source(&mut self, scope: &ProviderOperationScope) -> Result<()> {
        scope.validate()?;
        let publication = scope.publication();
        let digest = publication.digest()?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        // Unlike trusted-host task registration, this durable delegation always
        // requires an authenticated source identity, including its exact epoch.
        let authority = crate::source_authority::current(&tx)?.ok_or(Error::Denied)?;
        if self.source.as_ref() != Some(&authority.identity) {
            return Err(Error::Denied);
        }
        require_declared_publication(&tx, publication, &digest)?;
        let declared = ProviderOperationBinding {
            authority,
            scope: scope.clone(),
        };
        if let Some(previous) = binding(&tx, &scope.task().family, scope.node())? {
            if previous != declared {
                return Err(Error::Conflict("provider routing scope is immutable"));
            }
        } else {
            persistence::exec(
                &tx,
                "INSERT INTO provider_operation_scopes VALUES(?1,?2,?3,?4)",
                persistence::params![
                    scope.task().family.clone(),
                    scope.node().to_owned(),
                    weaver_contracts::body_digest(&serde_json::to_string(&declared)?),
                    serde_json::to_string(&declared)?
                ],
            )
            .map_err(db)?;
        }
        if let ProviderOperationScope::Fixed { task, .. } = scope {
            let key = weaver_contracts::PublicationKey {
                operation_id: publication.operation_id.clone(),
                digest,
            };
            crate::task_origins::default_binding(&tx, task, None, Some(&key))?;
            crate::store::register_task_in(&tx, task, Some(&key), None)?;
        }
        tx.commit().map_err(db)?;
        Ok(())
    }

    /// Trusted operation-owner read of a previously declared scope. It does not
    /// enroll a source or derive source privileges from the operation caller.
    pub fn provider_operation_cut(
        &mut self,
        family: &str,
        node: &str,
    ) -> Result<Option<ProviderOperationCut>> {
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        let observed = binding(&tx, family, node)?
            .map(|bound| cut(&tx, bound))
            .transpose()?;
        tx.commit().map_err(db)?;
        Ok(observed)
    }

    /// Finish Scheme derivation only against the same source, publication and
    /// catalog. Registration and these checks share the existing write scope.
    pub fn register_routed_task(
        &mut self,
        observed: &ProviderOperationCut,
        task: &Task,
        plan: &ProviderPlan,
    ) -> Result<()> {
        observed.binding.scope.admits(task, plan)?;
        let digest = plan.digest()?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        require_routed_cut(&tx, observed, &task.family, &plan.node, &digest)?;
        let publication = observed.binding.scope.publication();
        let key = weaver_contracts::PublicationKey {
            operation_id: publication.operation_id.clone(),
            digest: publication.digest()?,
        };
        crate::task_origins::default_binding(&tx, task, None, Some(&key))?;
        crate::store::register_task_in(&tx, task, Some(&key), None)?;
        tx.commit().map_err(db)?;
        Ok(())
    }
}

#[cfg(test)]
#[path = "../tests/unit/provider_routing.rs"]
mod tests;
