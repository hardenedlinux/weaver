//! One canonical provider invocation and affine response releases; no retry reset exists.
use crate::persistence::WriteScope;
use crate::{
    Ledger,
    store::{db, integer},
};
use std::collections::BTreeSet;
use weaver_contracts::{
    Error, ProviderPlan, ProviderReceipt, ProviderRoute, ProviderState, Result, Task,
};

/// Affine deciding-owner custody for one selected original provider invocation.
pub struct ProviderDispatch {
    plan: ProviderPlan,
    route: ProviderRoute,
    session: String,
    digest: String,
    binding: weaver_policy::BoundProviderPolicy,
}
impl ProviderDispatch {
    pub fn plan(&self) -> &ProviderPlan {
        &self.plan
    }
    pub fn route(&self) -> &ProviderRoute {
        &self.route
    }
}
/// Single-use response release burned before possible gRPC queue insertion.
pub struct ProviderRelease {
    sequence: u64,
    length: u64,
    digest: String,
    session: String,
    plan_digest: String,
    format: String,
}
impl Ledger {
    pub fn enqueue_provider(&mut self, plan: &ProviderPlan) -> Result<ProviderReceipt> {
        let digest = plan.digest()?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        if let Some(old) = receipt(&tx, &plan.family, &plan.node)? {
            if old.digest != digest {
                return Err(Error::Conflict("provider logical key already bound"));
            }
            if old.state != ProviderState::Queued {
                return Ok(old);
            }
        }
        any_authorized(&tx, plan, "admitProvider", None)?;
        crate::execution_exposure::require_family(&tx, &plan.family)?;
        let old = receipt(&tx, &plan.family, &plan.node)?;
        if old.is_none() {
            crate::execution_exposure::retain(
                &tx,
                crate::execution_exposure::ReservationClaim {
                    family: &plan.family,
                    node: &plan.node,
                    kind: crate::execution_exposure::ClaimKind::Provider,
                    member: "",
                    digest: &digest,
                    ceiling: plan.ceiling,
                },
            )?;
            let held = crate::persistence::exec(
                &tx,
                "UPDATE tasks SET held=held+?1 WHERE family=?2 AND ?1<=budget-held",
                crate::persistence::params![
                    (plan.ceiling as i64).to_owned(),
                    (plan.family).to_owned()
                ],
            )
            .map_err(db)?;
            if held != 1 {
                return Err(Error::Conflict("shared provider budget exhausted"));
            }
            crate::persistence::exec(&tx, "INSERT INTO provider_runs(family,node,digest,plan,reserved,state) VALUES(?1,?2,?3,?4,?5,'queued')", crate::persistence::params![(plan.family).to_owned(),(plan.node).to_owned(),(digest).to_owned(),(serde_json::to_string(plan)?).to_owned(),(plan.ceiling as i64).to_owned()]).map_err(db)?;
        } else {
            crate::persistence::exec(
                &tx,
                "UPDATE provider_runs SET plan=?1 WHERE family=?2 AND node=?3",
                crate::persistence::params![
                    (serde_json::to_string(plan)?).to_owned(),
                    (plan.family).to_owned(),
                    (plan.node).to_owned()
                ],
            )
            .map_err(db)?;
        }
        tx.commit().map_err(db)?;
        self.provider_receipt(&plan.family, &plan.node)?
            .ok_or(Error::Conflict("provider receipt missing"))
    }
    /// Eligibility is a local Rust credential/configuration observation, never a provider call.
    pub fn consume_provider(
        &mut self,
        family: &str,
        node: &str,
        eligible: &BTreeSet<String>,
    ) -> Result<ProviderDispatch> {
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        let record: Option<String> = crate::persistence::maybe(
            &tx,
            "SELECT plan FROM provider_runs WHERE family=?1 AND node=?2 AND state='queued'",
            crate::persistence::params![(family).to_owned(), (node).to_owned()],
            |r| r.get(0),
        )
        .map_err(db)?;
        let plan: ProviderPlan = serde_json::from_str(
            &record.ok_or(Error::Conflict("provider not queued or already consumed"))?,
        )?;
        let route = any_authorized(&tx, &plan, "invokeProvider", Some(eligible))?;
        let digest = plan.digest()?;
        require_exposure(&tx, &plan, &digest)?;
        let task_record: String = crate::persistence::one(
            &tx,
            "SELECT record FROM tasks WHERE family=?1",
            crate::persistence::params![plan.family.to_owned()],
            |row| row.get(0),
        )
        .map_err(db)?;
        let task: Task = serde_json::from_str(&task_record)?;
        let binding = weaver_policy::bind_provider(&task, &plan, &route)?;
        crate::persistence::exec(
            &tx,
            "UPDATE provider_runs SET state='unknown',target=?1 WHERE family=?2 AND node=?3",
            crate::persistence::params![
                (route.target).to_owned(),
                (family).to_owned(),
                (node).to_owned()
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(ProviderDispatch {
            plan,
            route,
            session: self.session.clone(),
            digest,
            binding,
        })
    }
    /// The exact consumed route and current authority serialize with the sole HTTPS request.
    pub fn dispatch_provider<T>(
        &mut self,
        permit: &ProviderDispatch,
        send: impl FnOnce() -> T,
    ) -> Result<T> {
        self.check_provider_session(permit)?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        guard_live(&tx, permit, "invokeProvider", 0, "protobuf")?;
        active(&tx, permit)?;
        // Persist a separate affine dispatch burn: borrowing a handle cannot repeat this callback.
        let burn = crate::persistence::exec(
            &tx,
            "UPDATE provider_runs SET dispatched=1 WHERE family=?1 AND node=?2 AND dispatched=0",
            crate::persistence::params![permit.plan.family.to_owned(), permit.plan.node.to_owned()],
        )
        .map_err(db)?;
        if burn != 1 {
            return Err(Error::Conflict("provider dispatch already burned"));
        }
        tx.commit().map_err(db)?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        guard_live(&tx, permit, "invokeProvider", 0, "protobuf")?;
        active(&tx, permit)?;
        let result = send();
        tx.commit().map_err(db)?;
        Ok(result)
    }
    pub fn prepare_provider_release(
        &mut self,
        permit: &ProviderDispatch,
        digest: &str,
        format: &str,
        length: u64,
    ) -> Result<ProviderRelease> {
        if length == 0 || length > 32 {
            return Err(Error::Invalid("provider release rows"));
        }
        self.check_provider_session(permit)?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        active(&tx, permit)?;
        started(&tx, permit)?;
        let seq: u64 = crate::persistence::one(
            &tx,
            "SELECT next_event FROM provider_runs WHERE family=?1 AND node=?2",
            crate::persistence::params![permit.plan.family.to_owned(), permit.plan.node.to_owned()],
            |r| integer(r, 0),
        )
        .map_err(db)?;
        for offset in 0..length {
            guard_live(&tx, permit, "emitProvider", seq + offset, format)?;
        }
        let uncertain:bool=crate::persistence::one(&tx, "SELECT EXISTS(SELECT 1 FROM provider_releases WHERE family=?1 AND node=?2 AND state='unknown')", crate::persistence::params![permit.plan.family.to_owned(),permit.plan.node.to_owned()], |r|r.get(0)).map_err(db)?;
        if uncertain || seq + length > 4096 {
            return Err(Error::Conflict("unknown or oversized provider response"));
        }
        crate::persistence::exec(
            &tx,
            "INSERT INTO provider_releases VALUES(?1,?2,?3,?4,?5,'unknown')",
            crate::persistence::params![
                (permit.plan.family).to_owned(),
                (permit.plan.node).to_owned(),
                (seq as i64).to_owned(),
                (length as i64).to_owned(),
                (digest).to_owned()
            ],
        )
        .map_err(db)?;
        crate::persistence::exec(
            &tx,
            "UPDATE provider_runs SET next_event=next_event+?3 WHERE family=?1 AND node=?2",
            crate::persistence::params![
                (permit.plan.family).to_owned(),
                (permit.plan.node).to_owned(),
                (length as i64).to_owned()
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(ProviderRelease {
            sequence: seq,
            length,
            digest: digest.into(),
            session: self.session.clone(),
            plan_digest: permit.digest.clone(),
            format: format.into(),
        })
    }
    pub fn release_provider<T>(
        &mut self,
        permit: &ProviderDispatch,
        release: ProviderRelease,
        format: &str,
        send: impl FnOnce(u64) -> Result<T>,
    ) -> Result<T> {
        self.check_provider_session(permit)?;
        if release.session != self.session {
            return Err(Error::Conflict("foreign release owner"));
        }
        if release.plan_digest != permit.digest || release.format != format {
            return Err(Error::Conflict("foreign provider release binding"));
        }
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        active(&tx, permit)?;
        for offset in 0..release.length {
            guard_live(
                &tx,
                permit,
                "emitProvider",
                release.sequence + offset,
                format,
            )?;
        }
        let digest:Option<String>=crate::persistence::maybe(&tx, "SELECT digest FROM provider_releases WHERE family=?1 AND node=?2 AND sequence=?3 AND length=?4 AND state='unknown'", crate::persistence::params![(permit.plan.family).to_owned(),(permit.plan.node).to_owned(),(release.sequence as i64).to_owned(),(release.length as i64).to_owned()], |r|r.get(0)).map_err(db)?;
        if digest.as_deref() != Some(&release.digest) {
            return Err(Error::Conflict("provider release binding"));
        }
        let output = send(release.sequence)?;
        crate::persistence::exec(&tx, "UPDATE provider_releases SET state='released' WHERE family=?1 AND node=?2 AND sequence=?3", crate::persistence::params![(permit.plan.family).to_owned(),(permit.plan.node).to_owned(),(release.sequence as i64).to_owned()]).map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(output)
    }
    pub fn complete_provider(&mut self, permit: &ProviderDispatch, format: &str) -> Result<()> {
        self.check_provider_session(permit)?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        active(&tx, permit)?;
        started(&tx, permit)?;
        guard_live(&tx, permit, "emitProvider", 0, format)?;
        let pending:bool=crate::persistence::one(&tx, "SELECT EXISTS(SELECT 1 FROM provider_releases WHERE family=?1 AND node=?2 AND state='unknown')", crate::persistence::params![permit.plan.family.to_owned(),permit.plan.node.to_owned()], |r|r.get(0)).map_err(db)?;
        if pending {
            return Err(Error::Conflict("response release unresolved"));
        }
        crate::persistence::exec(
            &tx,
            "UPDATE provider_runs SET state='complete' WHERE family=?1 AND node=?2",
            crate::persistence::params![permit.plan.family.to_owned(), permit.plan.node.to_owned()],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(())
    }
    pub fn provider_receipt(&self, family: &str, node: &str) -> Result<Option<ProviderReceipt>> {
        receipt(&self.connection, family, node)
    }
    fn check_provider_session(&self, p: &ProviderDispatch) -> Result<()> {
        if p.session != self.session {
            Err(Error::Conflict("foreign provider owner"))
        } else {
            Ok(())
        }
    }
}
fn active(tx: &WriteScope<'_>, p: &ProviderDispatch) -> Result<()> {
    let same:bool=crate::persistence::one(tx, "SELECT EXISTS(SELECT 1 FROM provider_runs WHERE family=?1 AND node=?2 AND digest=?3 AND target=?4 AND state='unknown')", crate::persistence::params![(p.plan.family).to_owned(),(p.plan.node).to_owned(),(p.digest).to_owned(),(p.route.target).to_owned()], |r|r.get(0)).map_err(db)?;
    if same {
        require_exposure(tx, &p.plan, &p.digest)
    } else {
        Err(Error::Conflict("provider consumption changed"))
    }
}
/// Refinement of ZeroTrust.consumptionCommitted / unknownRetained at actual use.
/// Never reconstruct a missing claim or refund a contradictory recovery image.
fn require_exposure(tx: &WriteScope<'_>, plan: &ProviderPlan, digest: &str) -> Result<()> {
    crate::execution_exposure::provider(tx, plan, digest)
}
fn started(tx: &WriteScope<'_>, p: &ProviderDispatch) -> Result<()> {
    let burned: bool = crate::persistence::one(
        tx,
        "SELECT dispatched FROM provider_runs WHERE family=?1 AND node=?2",
        crate::persistence::params![p.plan.family.to_owned(), p.plan.node.to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    if burned {
        Ok(())
    } else {
        Err(Error::Conflict("provider request not dispatched"))
    }
}
fn any_authorized(
    tx: &WriteScope<'_>,
    p: &ProviderPlan,
    action: &'static str,
    eligible: Option<&BTreeSet<String>>,
) -> Result<ProviderRoute> {
    for route in &p.routes {
        if eligible.is_none_or(|set| set.contains(&route.target))
            && guard(tx, p, route, action, 0, "protobuf").is_ok()
        {
            return Ok(route.clone());
        }
    }
    Err(Error::Denied)
}
fn guard(
    tx: &WriteScope<'_>,
    p: &ProviderPlan,
    r: &ProviderRoute,
    action: &'static str,
    sequence: u64,
    format: &str,
) -> Result<()> {
    crate::publication_barrier::require_resolved(tx)?;
    crate::task_publication::require(tx, &p.family)?;
    let (revision, fence, source): (u64, u64, String) = crate::persistence::one(
        tx,
        "SELECT revision,fence,policy FROM authority WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, integer(r, 1)?, r.get(2)?)),
    )
    .map_err(db)?;
    if (p.revision, p.fence) != (revision, fence) {
        return Err(Error::Conflict("stale provider authority"));
    }
    crate::provider_profiles::require(tx, p)?;
    let record: String = crate::persistence::one(
        tx,
        "SELECT record FROM tasks WHERE family=?1",
        crate::persistence::params![p.family.to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    let task: Task = serde_json::from_str(&record)?;
    weaver_policy::bind_provider(&task, p, r)?.authorize(
        &source,
        weaver_policy::ProviderCheck {
            action,
            sequence,
            format,
        },
    )
}
fn guard_live(
    tx: &WriteScope<'_>,
    p: &ProviderDispatch,
    action: &'static str,
    sequence: u64,
    format: &str,
) -> Result<()> {
    crate::publication_barrier::require_resolved(tx)?;
    crate::task_publication::require(tx, &p.plan.family)?;
    let (revision, fence, source): (u64, u64, String) = crate::persistence::one(
        tx,
        "SELECT revision,fence,policy FROM authority WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, integer(r, 1)?, r.get(2)?)),
    )
    .map_err(db)?;
    if (revision, fence) != (p.plan.revision, p.plan.fence) {
        return Err(Error::Conflict("stale provider release authority"));
    }
    crate::provider_profiles::require(tx, &p.plan)?;
    p.binding.authorize(
        &source,
        weaver_policy::ProviderCheck {
            action,
            sequence,
            format,
        },
    )
}
fn receipt(
    c: &crate::persistence::driver::Connection,
    family: &str,
    node: &str,
) -> Result<Option<ProviderReceipt>> {
    crate::persistence::maybe(c, "SELECT r.digest,r.state,r.target,r.reserved,t.held,r.next_event FROM provider_runs r JOIN tasks t ON t.family=r.family WHERE r.family=?1 AND r.node=?2", crate::persistence::params![(family).to_owned(),(node).to_owned()], |r|Ok(ProviderReceipt{family:family.into(),node:node.into(),digest:r.get(0)?,state:provider_state(r)?,target:r.get(2)?,reserved:integer(r,3)?,held:integer(r,4)?,events:integer(r,5)?})).map_err(db)
}
fn provider_state(row: &crate::persistence::Row) -> crate::persistence::Result<ProviderState> {
    let state: String = row.get(1)?;
    Ok(match state.as_str() {
        "queued" => ProviderState::Queued,
        "complete" => ProviderState::Complete,
        _ => ProviderState::Unknown,
    })
}
