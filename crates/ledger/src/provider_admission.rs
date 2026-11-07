// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bind an admissible provider plan and its reservation to the existing writer.
use super::{any_authorized, receipt};
use crate::{db, persistence::WriteScope};
use weaver_contracts::{DomainView, Error, ProviderPlan, ProviderReceipt, Result};

pub(super) fn admissible_receipt(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    digest: &str,
    oauth: Option<&crate::provider_oauth::PreparedUse>,
    progression: Option<&crate::ProviderProgression>,
) -> Result<Option<ProviderReceipt>> {
    tx.check_provider_oauth(oauth)?;
    crate::provider_workflow::require_admission(tx, plan, progression)?;
    let previous = receipt(tx, &plan.family, &plan.node)?;
    if previous.as_ref().is_some_and(|row| row.digest != digest) {
        return Err(Error::Conflict("provider logical key already bound"));
    }
    Ok(previous)
}

pub(super) fn store_authorized_provider_plan(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    (digest, encoded): (&str, String),
    catalog: &str,
    new_claim: bool,
    publication: &crate::provider_publication::Prepared,
    original: Option<&crate::task_origins::PreparedOriginal>,
) -> Result<()> {
    let selected = any_authorized(tx, plan, "admitProvider", None, publication)?;
    tx.provider_claim(|| crate::domains::require_view(tx, &selected.domains, original))?;
    if new_claim {
        reserve_provider_claim(tx, plan, digest, encoded, catalog, &selected.domains)?;
    } else {
        crate::persistence::exec(
            tx,
            "UPDATE provider_runs SET plan=?1 WHERE family=?2 AND node=?3",
            crate::persistence::params![encoded, (plan.family).to_owned(), (plan.node).to_owned()],
        )
        .map_err(db)?;
    }
    Ok(())
}

fn reserve_provider_claim(
    tx: &WriteScope<'_>,
    plan: &ProviderPlan,
    digest: &str,
    encoded: String,
    catalog: &str,
    domains: &DomainView,
) -> Result<()> {
    crate::execution_exposure::retain_in_view(
        tx,
        crate::execution_exposure::ReservationClaim {
            family: &plan.family,
            node: &plan.node,
            kind: crate::execution_exposure::ClaimKind::Provider,
            member: "",
            digest,
            ceiling: plan.ceiling,
        },
        domains,
    )?;
    let held = crate::persistence::exec(
        tx,
        "UPDATE tasks SET held=held+?1 WHERE family=?2 AND ?1<=budget-held",
        crate::persistence::params![(plan.ceiling as i64).to_owned(), (plan.family).to_owned()],
    )
    .map_err(db)?;
    if held != 1 {
        return Err(Error::Conflict("shared provider budget exhausted"));
    }
    crate::persistence::exec(tx, "INSERT INTO provider_runs(family,node,digest,plan,reserved,state) VALUES(?1,?2,?3,?4,?5,'queued')", crate::persistence::params![(plan.family).to_owned(),(plan.node).to_owned(),digest.to_owned(),encoded,(plan.ceiling as i64).to_owned()]).map_err(db)?;
    crate::metering::bind(tx, plan, digest, catalog)?;
    Ok(())
}
