// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One durable cursor advance for a bounded group of affine response ranges.
use super::{
    ProviderDispatch, ProviderRelease, RangeProgress, begin_progress_effect, guard_live_range,
    release_progress,
};
use crate::{
    Ledger, db,
    persistence::{ProviderScopePhase, WriteScope, exec, params},
};
use weaver_contracts::{Error, Result};

/// Maximum number of gRPC output ranges in one durable preparation.
pub const MAX_PROVIDER_PREPARATION_RANGES: usize = 4;
/// Maximum number of Cedar row decisions in one preparation ticket.
pub const MAX_PROVIDER_PREPARATION_ROWS: usize = 32;

impl Ledger {
    /// Prepare an ordered group of exact (payload digest, row count) ranges.
    /// Capabilities exist only after the complete native commit is acknowledged.
    pub fn prepare_provider_releases(
        &mut self,
        permit: &ProviderDispatch,
        ranges: &[(&str, u64)],
        format: &str,
    ) -> Result<Vec<ProviderRelease>> {
        let rows = group_length(ranges)?;
        self.check_provider_session(permit)?;
        let (tx, domains) = begin_progress_effect(
            &mut self.connection,
            permit,
            ProviderScopePhase::PrepareRange,
            &RangeProgress { _sealed: () },
        )?;
        let progress = release_progress(&tx, permit)?;
        let end = progress
            .next
            .checked_add(rows)
            .filter(|end| *end <= 4096)
            .ok_or(Error::Conflict("oversized provider response"))?;
        guard_live_range(
            &tx,
            permit,
            &domains,
            "emitProvider",
            progress.next..end,
            format,
        )?;
        if progress.pending {
            return Err(Error::Conflict("unknown provider response"));
        }
        stage_group(&tx, permit, ranges, progress.next, end)?;
        if ranges.len() == 1 {
            tx.commit().map_err(db)?;
        } else {
            tx.commit_range_prepare().map_err(db)?;
        }
        Ok(group_capabilities(permit, ranges, format, progress.next))
    }
}

impl Ledger {
    /// Burn an exact bounded manifest in one transaction, then publish its
    /// shared qualification. Only the first inert frame is staged before the
    /// native outcome; each individual frame still needs acknowledgment/use.
    pub fn release_provider_group_for_delivery<T>(
        &mut self,
        permit: &ProviderDispatch,
        releases: Vec<ProviderRelease>,
        format: &str,
        stage_first: impl FnOnce(u64, crate::ProviderDelivery) -> Result<T>,
    ) -> Result<(T, Vec<crate::ProviderDelivery>)> {
        self.check_provider_session(permit)?;
        validate_manifest(permit, &releases, format, &self.session)?;
        let owner = self.connection.execution_owner();
        let (mut tx, domains) = begin_progress_effect(
            &mut self.connection,
            permit,
            ProviderScopePhase::FinalQueue,
            &RangeProgress { _sealed: () },
        )?;
        guard_manifest(&tx, permit, &domains, &releases, format)?;
        let staged = stage_snapshot(&mut tx, owner, permit, &releases, format, stage_first)?;
        tx.commit_delivery().map_err(db)?;
        Ok(staged)
    }
}

fn guard_manifest(
    tx: &WriteScope<'_>,
    p: &ProviderDispatch,
    domains: &weaver_contracts::DomainView,
    releases: &[ProviderRelease],
    format: &str,
) -> Result<()> {
    let first = releases.first().ok_or(Error::Conflict("empty snapshot"))?;
    let last = releases.last().ok_or(Error::Conflict("empty snapshot"))?;
    guard_live_range(
        tx,
        p,
        domains,
        "emitProvider",
        first.sequence..last.sequence + last.length,
        format,
    )?;
    for (index, release) in releases.iter().enumerate() {
        let digest = if index == 0 {
            super::release_digest(tx, p, release)?
        } else {
            super::exact_release_digest(tx, p, release)?
        };
        if digest.as_deref() != Some(release.digest.as_str()) {
            return Err(Error::Conflict("provider release binding"));
        }
    }
    Ok(())
}

fn stage_snapshot<T>(
    tx: &mut WriteScope<'_>,
    owner: std::sync::Arc<crate::persistence::owner::Owner>,
    p: &ProviderDispatch,
    releases: &[ProviderRelease],
    format: &str,
    stage_first: impl FnOnce(u64, crate::ProviderDelivery) -> Result<T>,
) -> Result<(T, Vec<crate::ProviderDelivery>)> {
    let receipt = tx.delivery_receipt().map_err(db)?;
    let mut deliveries =
        crate::ProviderDelivery::group(owner, receipt, tx.delivery_scope(), p, releases, format)
            .into_iter();
    let first = deliveries
        .next()
        .ok_or(Error::Conflict("empty provider snapshot"))?;
    let result = tx.queue_effect(|| {
        p.require_oauth_time()?;
        stage_first(releases[0].sequence, first)
    })?;
    for release in releases {
        super::mark_release(tx, p, release)?;
    }
    Ok((result, deliveries.collect()))
}

fn validate_manifest(
    p: &ProviderDispatch,
    releases: &[ProviderRelease],
    format: &str,
    session: &str,
) -> Result<()> {
    let specs: Vec<_> = releases
        .iter()
        .map(|r| (r.digest.as_str(), r.length))
        .collect();
    group_length(&specs)?;
    for (index, r) in releases.iter().enumerate() {
        if r.session != session
            || r.plan_digest != p.digest
            || r.format != format
            || r.sequence
                .checked_add(r.length)
                .is_none_or(|end| end > 4096)
        {
            return Err(Error::Conflict("foreign provider snapshot manifest"));
        }
        if index > 0 {
            let prior = &releases[index - 1];
            if r.sequence != prior.sequence + prior.length || r.predecessor != Some(prior.sequence)
            {
                return Err(Error::Conflict("unordered provider snapshot manifest"));
            }
        }
    }
    Ok(())
}

fn group_length(ranges: &[(&str, u64)]) -> Result<u64> {
    if ranges.is_empty()
        || ranges.len() > MAX_PROVIDER_PREPARATION_RANGES
        || ranges.iter().any(|(_, rows)| !(1..=32).contains(rows))
    {
        return Err(Error::Invalid("provider release rows or group width"));
    }
    let rows: u64 = ranges.iter().map(|(_, rows)| rows).sum();
    if rows > MAX_PROVIDER_PREPARATION_ROWS as u64 {
        return Err(Error::Invalid("provider preparation row limit"));
    }
    Ok(rows)
}

fn stage_group(
    tx: &WriteScope<'_>,
    permit: &ProviderDispatch,
    ranges: &[(&str, u64)],
    start: u64,
    end: u64,
) -> Result<()> {
    let family = permit.plan.family.as_str();
    let node = permit.plan.node.as_str();
    futures_executor::block_on(async {
        let mut insert = tx
            .prepare_cached("INSERT INTO provider_releases VALUES(?1,?2,?3,?4,?5,'unknown')")
            .await?;
        for (sequence, _, digest, length) in range_positions(ranges, start) {
            insert
                .execute(params![
                    family,
                    node,
                    sequence as i64,
                    length as i64,
                    digest
                ])
                .await?;
        }
        Ok(())
    })
    .map_err(db)?;
    let advanced = exec(
        tx,
        "UPDATE provider_runs SET next_event=?3 WHERE family=?1 AND node=?2 AND next_event=?4",
        params![family, node, end as i64, start as i64],
    )
    .map_err(db)?;
    if advanced != 1 {
        return Err(Error::Conflict("provider preparation cursor changed"));
    }
    Ok(())
}

fn group_capabilities(
    permit: &ProviderDispatch,
    ranges: &[(&str, u64)],
    format: &str,
    start: u64,
) -> Vec<ProviderRelease> {
    range_positions(ranges, start)
        .map(|(sequence, predecessor, digest, length)| ProviderRelease {
            sequence,
            predecessor,
            length,
            digest: digest.into(),
            session: permit.session.clone(),
            plan_digest: permit.digest.clone(),
            format: format.into(),
        })
        .collect()
}

fn range_positions<'a>(
    ranges: &'a [(&'a str, u64)],
    start: u64,
) -> impl Iterator<Item = (u64, Option<u64>, &'a str, u64)> {
    ranges.iter().scan(
        (start, None),
        |(sequence, predecessor), &(digest, length)| {
            let position = (*sequence, *predecessor, digest, length);
            *predecessor = Some(*sequence);
            *sequence += length;
            Some(position)
        },
    )
}

pub(super) fn ordered_release_digest(
    tx: &WriteScope<'_>,
    permit: &ProviderDispatch,
    release: &ProviderRelease,
    predecessor: u64,
) -> Result<Option<String>> {
    crate::persistence::maybe_current(
        tx,
        "SELECT r.digest FROM provider_releases r
         WHERE r.family=?1 AND r.node=?2 AND r.sequence=?3 AND r.length=?4 AND r.state='unknown'
           AND EXISTS(SELECT 1 FROM provider_releases p
              WHERE p.family=?1 AND p.node=?2 AND p.sequence=?5
                AND p.sequence+p.length=?3 AND p.state='released')",
        params![
            permit.plan.family.as_str(),
            permit.plan.node.as_str(),
            release.sequence as i64,
            release.length as i64,
            predecessor as i64
        ],
        |row| row.get(0),
    )
    .map_err(db)
}
