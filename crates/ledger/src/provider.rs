// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One canonical provider invocation and affine response releases; no retry reset exists.
use crate::persistence::{ProviderScopePhase, WriteScope};
use crate::{
    Ledger,
    store::{db, integer},
};
use std::collections::BTreeSet;
use weaver_contracts::{
    DomainView, Error, ProviderOAuthUse, ProviderPlan, ProviderReceipt, ProviderRoute,
    ProviderState, Result, Task,
};

/// Affine deciding-owner custody for one selected original provider invocation.
pub struct ProviderDispatch {
    plan: ProviderPlan,
    route: ProviderRoute,
    session: String,
    digest: String,
    binding: weaver_policy::BoundProviderPolicy,
    profile: crate::provider_profiles::CheckedProfile,
    publication: crate::provider_publication::Prepared,
    domains: weaver_contracts::DomainStamp,
    original: Option<crate::task_origins::PreparedOriginal>,
    oauth: Option<crate::provider_oauth::PreparedUse>,
    oauth_expires: Option<u64>,
}
impl ProviderDispatch {
    pub fn plan(&self) -> &ProviderPlan {
        &self.plan
    }
    pub fn protocol(&self) -> weaver_contracts::ProviderProtocol {
        self.binding.protocol()
    }
    pub fn route(&self) -> &ProviderRoute {
        &self.route
    }
    /// Expiration bound retained from the consumed grant for the TLS writer.
    pub fn oauth_expires(&self) -> Option<u64> {
        self.oauth_expires
    }
    fn require_oauth_time(&self) -> Result<()> {
        if let Some(expires) = self.oauth_expires
            && crate::provider_oauth::now()? >= expires
        {
            return Err(Error::Denied);
        }
        Ok(())
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
impl ProviderRelease {
    /// Inert sequence metadata for pure frame encoding, never send permission.
    pub fn first_sequence(&self) -> u64 {
        self.sequence
    }
}
impl Ledger {
    /// Cancel pending provider range admission when the client or server leaves.
    /// The predicate must be nonblocking. Granted transactions still complete
    /// or roll back through their existing guarded effect paths.
    pub fn set_provider_range_cancellation(
        &mut self,
        cancelled: impl Fn() -> bool + Send + Sync + 'static,
    ) {
        self.connection.range_cancelled = Some(std::sync::Arc::new(cancelled));
    }
    /// Enable bounded diagnostic observations for this ledger only.
    #[cfg(feature = "commit-observer")]
    pub fn trace_provider_scopes(&mut self) {
        self.connection.trace_provider_scopes();
    }

    /// Recorded scopes in this ledger's session.
    #[cfg(feature = "commit-observer")]
    pub fn provider_scope_samples(&self) -> &[crate::persistence::ProviderScopeSample] {
        self.connection.provider_scope_samples()
    }
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
        let digest = plan.digest()?;
        let encoded = serde_json::to_string(plan)?;
        let prepared = self
            .connection
            .prepare_provider_oauth(oauth, "provider:execute")?;
        let publication = self.connection.prepare_provider_publication(&plan.family);
        let original = self.connection.prepare_provider_original(&plan.family);
        self.connection.prepare_provider_domain();
        let tx =
            crate::persistence::begin_family(&mut self.connection, &plan.family).map_err(db)?;
        tx.check_provider_oauth(prepared.as_ref())?;
        let new_claim = match receipt(&tx, &plan.family, &plan.node)? {
            Some(old) if old.digest != digest => {
                return Err(Error::Conflict("provider logical key already bound"));
            }
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
        self.consume_provider_with_oauth(family, node, eligible, None)
    }

    /// Consume the original under the current issuer grant and Cedar view.
    pub fn consume_provider_with_oauth(
        &mut self,
        family: &str,
        node: &str,
        eligible: &BTreeSet<String>,
        oauth: Option<&ProviderOAuthUse>,
    ) -> Result<ProviderDispatch> {
        let prepared = self
            .connection
            .prepare_provider_oauth(oauth, "provider:execute")?;
        let publication = self.connection.prepare_provider_publication(family)?;
        let original = self.connection.prepare_provider_original(family);
        #[cfg(feature = "commit-observer")]
        warm_release_programs(&self.connection);
        self.connection.prepare_provider_domain();
        let tx = crate::persistence::begin_family(&mut self.connection, family).map_err(db)?;
        let oauth_expires = tx.check_provider_oauth(prepared.as_ref())?;
        let (plan, selected, digest) = authorize_provider_consumption(
            &tx,
            family,
            node,
            eligible,
            &publication,
            original.as_ref(),
        )?;
        mark_provider_consumed(&tx, family, node, &selected.route.target)?;
        tx.commit().map_err(db)?;
        Ok(ProviderDispatch {
            plan,
            route: selected.route,
            session: self.session.clone(),
            digest,
            binding: selected.binding,
            profile: selected.profile,
            publication,
            domains: selected.domains.stamp,
            original,
            oauth: prepared,
            oauth_expires,
        })
    }
    /// The exact consumed route and current authority serialize with the sole HTTPS request.
    /// A failed callback rolls back the final scope before its commit window;
    /// the earlier affine burn and original unknown reservation remain spent.
    pub fn dispatch_provider<T>(
        &mut self,
        permit: &ProviderDispatch,
        send: impl FnOnce() -> Result<T>,
    ) -> Result<T> {
        self.check_provider_session(permit)?;
        burn_dispatch(&mut self.connection, permit)?;
        let (mut tx, domains) =
            begin_provider_effect(&mut self.connection, permit, ProviderScopePhase::Other)?;
        guard_live(&tx, permit, &domains, "invokeProvider", 0, "protobuf")?;
        let result = tx.request_effect(send)?;
        record_dispatch_callback(&tx, permit)?;
        tx.commit_provider().map_err(db)?;
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
        let (tx, domains) = begin_provider_effect(
            &mut self.connection,
            permit,
            ProviderScopePhase::PrepareRange,
        )?;
        let progress = release_progress(&tx, permit)?;
        let seq = progress.next;
        guard_live_range(
            &tx,
            permit,
            &domains,
            "emitProvider",
            seq..seq + length,
            format,
        )?;
        if progress.pending || seq + length > 4096 {
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
        let (mut tx, domains) =
            begin_provider_effect(&mut self.connection, permit, ProviderScopePhase::FinalQueue)?;
        guard_live_range(
            &tx,
            permit,
            &domains,
            "emitProvider",
            release.sequence..release.sequence + release.length,
            format,
        )?;
        if release_digest(&tx, permit, &release)?.as_deref() != Some(&release.digest) {
            return Err(Error::Conflict("provider release binding"));
        }
        let output = tx.queue_effect(|| {
            permit.require_oauth_time()?;
            send(release.sequence)
        })?;
        mark_release(&tx, permit, &release)?;
        tx.commit().map_err(db)?;
        Ok(output)
    }
    pub fn complete_provider(&mut self, permit: &ProviderDispatch, format: &str) -> Result<()> {
        self.complete_provider_with_usage(permit, format, None)
    }

    pub fn complete_provider_with_usage(
        &mut self,
        permit: &ProviderDispatch,
        format: &str,
        tokens: Option<[u64; 4]>,
    ) -> Result<()> {
        self.check_provider_session(permit)?;
        let (tx, domains) =
            begin_provider_effect(&mut self.connection, permit, ProviderScopePhase::Other)?;
        let progress = release_progress(&tx, permit)?;
        guard_live(&tx, permit, &domains, "emitProvider", 0, format)?;
        if progress.pending {
            return Err(Error::Conflict("response release unresolved"));
        }
        crate::persistence::exec(
            &tx,
            "UPDATE provider_runs SET state='complete' WHERE family=?1 AND node=?2",
            crate::persistence::params![permit.plan.family.to_owned(), permit.plan.node.to_owned()],
        )
        .map_err(db)?;
        if let Some(tokens) = tokens {
            crate::persistence::exec(
                &tx,
                "INSERT INTO provider_terminal_usage VALUES(?1,?2,?3)",
                [
                    permit.plan.family.as_str(),
                    permit.plan.node.as_str(),
                    &serde_json::to_string(&tokens)?,
                ],
            )
            .map_err(db)?;
        }
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
fn burn_dispatch(
    session: &mut crate::persistence::Session,
    permit: &ProviderDispatch,
) -> Result<()> {
    let (tx, domains) = begin_provider_effect(session, permit, ProviderScopePhase::Other)?;
    guard_live(&tx, permit, &domains, "invokeProvider", 0, "protobuf")?;
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
    Ok(())
}
fn record_dispatch_callback(tx: &WriteScope<'_>, permit: &ProviderDispatch) -> Result<()> {
    // 2 records a successful guarded callback transaction, NOT
    // writer seal, remote execution, known usage, or refund authority.
    // Both 1 and 2 permanently retain the original affine dispatch burn.
    let recorded = crate::persistence::exec(
        tx,
        "UPDATE provider_runs SET dispatched=2 WHERE family=?1 AND node=?2 AND dispatched=1",
        crate::persistence::params![permit.plan.family.to_owned(), permit.plan.node.to_owned()],
    )
    .map_err(db)?;
    if recorded != 1 {
        return Err(Error::Conflict("provider dispatch record changed"));
    }
    Ok(())
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

fn authorize_provider_consumption(
    tx: &WriteScope<'_>,
    family: &str,
    node: &str,
    eligible: &BTreeSet<String>,
    publication: &crate::provider_publication::Prepared,
    original: Option<&crate::task_origins::PreparedOriginal>,
) -> Result<(ProviderPlan, AuthorizedRoute, String)> {
    let record: Option<String> = crate::persistence::maybe(
        tx,
        "SELECT plan FROM provider_runs WHERE family=?1 AND node=?2 AND state='queued'",
        crate::persistence::params![(family).to_owned(), (node).to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    let plan: ProviderPlan = serde_json::from_str(
        &record.ok_or(Error::Conflict("provider not queued or already consumed"))?,
    )?;
    let selected = any_authorized(tx, &plan, "invokeProvider", Some(eligible), publication)?;
    let digest = plan.digest()?;
    tx.provider_claim(|| {
        crate::execution_exposure::provider(tx, &plan, &digest, &selected.domains, original, None)
    })?;
    Ok((plan, selected, digest))
}

fn mark_provider_consumed(
    tx: &WriteScope<'_>,
    family: &str,
    node: &str,
    target: &str,
) -> Result<()> {
    let consumed = crate::persistence::exec(
        tx,
        "UPDATE provider_runs SET state='unknown',target=?1 WHERE family=?2 AND node=?3 AND state='queued'",
        crate::persistence::params![
            target,
            (family).to_owned(),
            (node).to_owned()
        ],
    )
    .map_err(db)?;
    if consumed != 1 {
        return Err(Error::Conflict("provider consumption lost queued row"));
    }
    Ok(())
}

fn begin_provider_effect<'a>(
    session: &'a mut crate::persistence::Session,
    p: &ProviderDispatch,
    phase: ProviderScopePhase,
) -> Result<(WriteScope<'a>, DomainView)> {
    let tx = crate::persistence::begin_provider_use(session, &p.plan.family, &p.domains, phase)
        .map_err(db)?;
    // A retired stamp may name old lock keys. Before any mutation or
    // callback, require the live stamp to identify exactly those keys.
    let actual = tx.provider_domain(|| crate::domains::provider_view(&tx, &p.plan.family))?;
    if actual.canonical_family != p.plan.family || actual.stamp != p.domains {
        return Err(Error::Conflict(
            "execution domain migrated; old permit fenced",
        ));
    }
    tx.provider_claim(|| {
        crate::execution_exposure::provider(
            &tx,
            &p.plan,
            &p.digest,
            &actual,
            p.original.as_ref(),
            Some(&p.route.target),
        )
    })?;
    Ok((tx, actual))
}
#[cfg(feature = "commit-observer")]
thread_local! {
    static CACHED_RELEASE_PROGRAMS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
    static SEPARATE_RELEASE_READS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Same-image comparison with individual progress probes.
#[cfg(feature = "commit-observer")]
pub fn use_separate_release_reads(separate: bool) {
    SEPARATE_RELEASE_READS.set(separate);
}

/// Same-image diagnostic with compatible prewarmed release programs.
#[cfg(feature = "commit-observer")]
pub fn use_cached_release_programs(cached: bool) {
    CACHED_RELEASE_PROGRAMS.set(cached);
}

const RELEASE_LOOKUP: &str = "SELECT digest FROM provider_releases
    WHERE family=?1 AND node=?2 AND sequence=?3 AND length=?4 AND state='unknown'";
const RELEASE_MARK: &str = "UPDATE provider_releases SET state='released'
    WHERE family=?1 AND node=?2 AND sequence=?3";

#[cfg(feature = "commit-observer")]
fn warm_release_programs(connection: &crate::persistence::driver::Connection) {
    if CACHED_RELEASE_PROGRAMS.get() {
        for sql in [RELEASE_LOOKUP, RELEASE_MARK] {
            let _ = futures_executor::block_on(connection.prepare_cached(sql));
        }
    }
}

fn release_digest(
    tx: &WriteScope<'_>,
    permit: &ProviderDispatch,
    release: &ProviderRelease,
) -> Result<Option<String>> {
    let params = crate::persistence::params![
        permit.plan.family.as_str(),
        permit.plan.node.as_str(),
        release.sequence as i64,
        release.length as i64
    ];
    #[cfg(feature = "commit-observer")]
    if CACHED_RELEASE_PROGRAMS.get() {
        return futures_executor::block_on(async {
            let mut program = tx.prepare_cached(RELEASE_LOOKUP).await?;
            let mut cursor = program.query(params).await?;
            cursor.next().await?.as_ref().map(|r| r.get(0)).transpose()
        })
        .map_err(db);
    }
    crate::persistence::maybe(tx, RELEASE_LOOKUP, params, |r| r.get(0)).map_err(db)
}

fn mark_release(
    tx: &WriteScope<'_>,
    permit: &ProviderDispatch,
    release: &ProviderRelease,
) -> Result<()> {
    let params = crate::persistence::params![
        permit.plan.family.as_str(),
        permit.plan.node.as_str(),
        release.sequence as i64
    ];
    #[cfg(feature = "commit-observer")]
    if CACHED_RELEASE_PROGRAMS.get() {
        futures_executor::block_on(async {
            tx.prepare_cached(RELEASE_MARK).await?.execute(params).await
        })
        .map_err(db)?;
        return Ok(());
    }
    crate::persistence::exec(tx, RELEASE_MARK, params).map_err(db)?;
    Ok(())
}

struct ReleaseProgress {
    next: u64,
    pending: bool,
}

fn release_progress(tx: &WriteScope<'_>, p: &ProviderDispatch) -> Result<ReleaseProgress> {
    let key = [p.plan.family.as_str(), p.plan.node.as_str()];
    #[cfg(feature = "commit-observer")]
    if SEPARATE_RELEASE_READS.get() {
        let burned: bool = crate::persistence::one(
            tx,
            "SELECT dispatched<>0 FROM provider_runs WHERE family=?1 AND node=?2",
            key,
            |r| r.get(0),
        )
        .map_err(db)?;
        if !burned {
            return Err(Error::Conflict("provider request not dispatched"));
        }
        let next = crate::persistence::one(
            tx,
            "SELECT next_event FROM provider_runs WHERE family=?1 AND node=?2",
            key,
            |r| integer(r, 0),
        )
        .map_err(db)?;
        let pending = crate::persistence::one(tx,
            "SELECT EXISTS(SELECT 1 FROM provider_releases WHERE family=?1 AND node=?2 AND state='unknown')",
            key, |r| r.get(0)).map_err(db)?;
        return Ok(ReleaseProgress { next, pending });
    }
    // Same transaction and held domain stripes as the effect guard.
    // This is a projection of current progress, never an authority receipt.
    let (burned, progress) = crate::persistence::one_current(
        tx,
        "SELECT dispatched<>0,next_event,EXISTS(
            SELECT 1 FROM provider_releases WHERE family=?1 AND node=?2 AND state='unknown'
         ) FROM provider_runs WHERE family=?1 AND node=?2",
        key,
        |r| {
            Ok((
                r.get::<bool>(0)?,
                ReleaseProgress {
                    next: integer(r, 1)?,
                    pending: r.get(2)?,
                },
            ))
        },
    )
    .map_err(db)?;
    if !burned {
        return Err(Error::Conflict("provider request not dispatched"));
    }
    Ok(progress)
}
struct AuthorizedRoute {
    route: ProviderRoute,
    binding: weaver_policy::BoundProviderPolicy,
    profile: crate::provider_profiles::CheckedProfile,
    domains: DomainView,
}

fn any_authorized(
    tx: &WriteScope<'_>,
    p: &ProviderPlan,
    action: &'static str,
    eligible: Option<&BTreeSet<String>>,
    publication: &crate::provider_publication::Prepared,
) -> Result<AuthorizedRoute> {
    let domains = tx.provider_domain(|| crate::domains::provider_view(tx, &p.family))?;
    if domains.canonical_family != p.family {
        return Err(Error::Conflict("family alias is not an executable origin"));
    }
    for route in &p.routes {
        if eligible.is_none_or(|set| set.contains(&route.target))
            && let Ok((binding, profile)) = guard(tx, p, route, action, &domains, publication)
        {
            return Ok(AuthorizedRoute {
                route: route.clone(),
                binding,
                profile,
                domains,
            });
        }
    }
    Err(Error::Denied)
}
fn guard(
    tx: &WriteScope<'_>,
    p: &ProviderPlan,
    r: &ProviderRoute,
    action: &'static str,
    domains: &DomainView,
    publication: &crate::provider_publication::Prepared,
) -> Result<(
    weaver_policy::BoundProviderPolicy,
    crate::provider_profiles::CheckedProfile,
)> {
    tx.provider_pending(|| crate::publication_barrier::require_clear(tx))?;
    let source = publication.policy(tx, p, "stale provider authority")?;
    let profile = tx.provider_profile(|| crate::provider_profiles::require(tx, p))?;
    let record: String = crate::persistence::one(
        tx,
        "SELECT record FROM tasks WHERE family=?1",
        crate::persistence::params![p.family.to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    let task: Task = serde_json::from_str(&record)?;
    let binding = weaver_policy::bind_provider(&task, p, r)?;
    tx.provider_cedar(|| {
        binding.authorize(
            &source,
            weaver_policy::ProviderCheck {
                action,
                sequence: 0,
                format: "protobuf",
                domains: Some(domains),
            },
        )
    })?;
    Ok((binding, profile))
}

fn guard_live(
    tx: &WriteScope<'_>,
    p: &ProviderDispatch,
    domains: &weaver_contracts::DomainView,
    action: &'static str,
    sequence: u64,
    format: &str,
) -> Result<()> {
    guard_live_range(tx, p, domains, action, sequence..sequence + 1, format)
}
// State is read after the deciding lock is acquired, and cannot escape this
// call. No SQL write, wait, or external callback occurs between row decisions.
// Each row still receives a distinct Cedar request for its actual sequence.
fn guard_live_range(
    tx: &WriteScope<'_>,
    p: &ProviderDispatch,
    domains: &weaver_contracts::DomainView,
    action: &'static str,
    sequences: std::ops::Range<u64>,
    format: &str,
) -> Result<()> {
    tx.provider_pending(|| crate::publication_barrier::require_clear(tx))?;
    tx.check_provider_oauth(p.oauth.as_ref())?;
    let source = p
        .publication
        .policy(tx, &p.plan, "stale provider release authority")?;
    tx.provider_profile(|| p.profile.require_current(tx, &p.plan))?;
    for sequence in sequences {
        tx.provider_cedar(|| {
            p.binding.authorize(
                &source,
                weaver_policy::ProviderCheck {
                    action,
                    sequence,
                    format,
                    domains: Some(domains),
                },
            )
        })?;
    }
    Ok(())
}
pub(crate) fn receipt(
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
