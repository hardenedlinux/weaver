// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Bind an admissible provider plan and its reservation to the existing writer.
use super::{AdmissionRequest, any_authorized, governor_commit_trace, governor_timing, receipt};
use crate::{Ledger, db, persistence::WriteScope};
use std::time::Instant;
use weaver_contracts::{
    DomainView, Error, ProviderOAuthUse, ProviderPlan, ProviderReceipt, ProviderState, Result,
};

impl Ledger {
    pub fn enqueue_provider(&mut self, plan: &ProviderPlan) -> Result<ProviderReceipt> {
        self.enqueue_catalog_provider(plan, "")
    }

    pub fn enqueue_catalog_provider(
        &mut self,
        plan: &ProviderPlan,
        catalog: &str,
    ) -> Result<ProviderReceipt> {
        self.enqueue_provider_with_oauth(plan, catalog, None)
    }

    /// Bind the request observation before exposing any reservation or prior outcome.
    pub fn enqueue_provider_with_oauth(
        &mut self,
        plan: &ProviderPlan,
        catalog: &str,
        oauth: Option<&ProviderOAuthUse>,
    ) -> Result<ProviderReceipt> {
        self.enqueue_provider_progression(plan, catalog, oauth, None)
    }

    /// Commit the prepared successor frontier with the existing claim and hold.
    pub fn enqueue_provider_progression(
        &mut self,
        plan: &ProviderPlan,
        catalog: &str,
        oauth: Option<&ProviderOAuthUse>,
        progression: Option<&crate::ProviderProgression>,
    ) -> Result<ProviderReceipt> {
        let digest = plan.digest()?;
        let encoded = serde_json::to_string(plan)?;
        let prepared = self
            .connection
            .prepare_provider_oauth(oauth, "provider:execute")?;
        let publication = self.connection.prepare_provider_publication(&plan.family);
        let original = self.connection.prepare_provider_original(&plan.family);
        self.connection.prepare_provider_domain();
        let transaction = (progression.is_some() && governor_timing()).then(Instant::now);
        let tx = crate::persistence::begin_provider_admission(
            &mut self.connection,
            &plan.family,
            &AdmissionRequest { _sealed: () },
        )
        .map_err(db)?;
        let new_claim =
            match admissible_receipt(&tx, plan, &digest, prepared.as_ref(), progression)? {
                Some(old) if old.state != ProviderState::Queued => return Ok(old),
                Some(_) => false,
                None => true,
            };
        store_authorized_provider_plan(
            &tx,
            plan,
            (&digest, encoded),
            catalog,
            new_claim,
            &publication?,
            original.as_ref(),
        )?;
        commit_provider_progression(tx, plan, &digest, progression, new_claim, transaction)?;
        self.provider_receipt(&plan.family, &plan.node)?
            .ok_or(Error::Conflict("provider receipt missing"))
    }
}

fn commit_provider_progression(
    tx: WriteScope<'_>,
    plan: &ProviderPlan,
    digest: &str,
    progression: Option<&crate::ProviderProgression>,
    new_claim: bool,
    transaction: Option<Instant>,
) -> Result<()> {
    crate::provider_workflow::record_admission(&tx, plan, digest, progression, new_claim)?;
    tx.commit_provider_admission().map_err(db)?;
    if new_claim && progression.is_some() {
        governor_commit_trace("reserve", plan, transaction);
    }
    Ok(())
}

fn admissible_receipt(
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

fn store_authorized_provider_plan(
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
