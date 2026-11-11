// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One local ordered fact feed. Staging and installation are separate authority transactions.
use std::collections::BTreeSet;

use crate::{
    Ledger,
    persistence::{begin, driver::Connection, exec, maybe_current, params, read_all_current},
    source_authority,
    store::{db, integer},
};
use weaver_contracts::{
    Error, FactBarrier, FactFeed, FactIntent, FactResolution, FactWork, Result, SourceIdentity,
    body_digest, decode,
};

const GENESIS: &str = "0000000000000000000000000000000000000000000000000000000000000000";
const MAX_PENDING: u64 = 64;

/// Either a detached derivation request or the original committed resolution.
pub enum FactPreparation {
    Pending(FactWork),
    Resolved(FactResolution),
}

/// The current hard-fact cut and ordered pending barriers for its authenticated source.
pub struct FactFeedState {
    pub domain: String,
    pub source_epoch: u64,
    pub floor: u64,
    pub revision: u64,
    pub snapshot: String,
    pub available: Option<bool>,
    pub pending: Vec<(FactBarrier, bool)>,
}

struct Head {
    feed: FactFeed,
    floor: u64,
    revision: u64,
    snapshot: String,
    pending: Option<String>,
}

fn head(c: &Connection) -> Result<Option<Head>> {
    let row = maybe_current(
        c,
        "SELECT record,floor,revision,snapshot,pending FROM main.hard_fact_feed WHERE singleton=1",
        (),
        |row| {
            Ok((
                row.get::<String>(0)?,
                integer(row, 1)?,
                integer(row, 2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        },
    )
    .map_err(db)?;
    row.map(|(record, floor, revision, snapshot, pending)| {
        Ok(Head {
            feed: decode(record.as_bytes())?,
            floor,
            revision,
            snapshot,
            pending,
        })
    })
    .transpose()
}

fn authorize(c: &Connection, caller: Option<&SourceIdentity>, feed: &FactFeed) -> Result<()> {
    if caller != Some(&feed.authority.identity)
        || source_authority::current(c)?.as_ref() != Some(&feed.authority)
    {
        return Err(Error::Denied);
    }
    Ok(())
}

pub(crate) fn require_enrollment(c: &Connection, caller: &SourceIdentity) -> Result<()> {
    if let Some(head) = head(c)?
        && (head.feed.authority.epoch != 0 || head.feed.authority.identity != *caller)
    {
        return Err(Error::Denied);
    }
    Ok(())
}

pub(crate) fn has_fact_state(c: &Connection) -> Result<bool> {
    Ok(
        head(c)?
            .is_some_and(|head| head.floor != 0 || head.revision != 0 || head.pending.is_some()),
    )
}

#[derive(PartialEq, Eq)]
pub(crate) struct UseCut {
    pub(crate) expects_workflow_result: bool,
    floor: u64,
    revision: u64,
    snapshot: String,
}

pub(crate) fn require_available(
    c: &Connection,
    family: &str,
    node: &str,
) -> Result<Option<UseCut>> {
    let scoped = maybe_current(
        c,
        "SELECT feed.record,feed.revision,feed.pending IS NOT NULL,
          feed.floor,feed.snapshot,
          EXISTS(SELECT 1 FROM json_each(feed.unavailable) WHERE value=?2)
         FROM main.hard_fact_feed feed
         WHERE feed.family=?1 OR EXISTS(
           SELECT 1 FROM main.family_origins own JOIN main.family_origins alias ON own.origin=alias.origin
           WHERE own.family=feed.family AND alias.family=?1)",
        params![family.to_owned(), node.to_owned()],
        |row| {
            Ok((
                row.get::<String>(0)?,
                integer(row, 1)?,
                row.get::<bool>(2)?,
                integer(row, 3)?,
                row.get::<String>(4)?,
                row.get::<bool>(5)?,
            ))
        },
    )
    .map_err(db)?;
    if let Some((record, revision, pending, floor, snapshot, unavailable)) = scoped {
        let feed: FactFeed = decode(record.as_bytes())?;
        if !feed.workflow_path.is_empty() && feed.family != family {
            return Err(Error::Conflict("workflow requires the original family"));
        }
        if revision == 0
            || pending
            || unavailable
            || source_authority::current(c)?.as_ref() != Some(&feed.authority)
        {
            return Err(Error::Conflict("hard fact unavailable"));
        }
        return Ok(Some(UseCut {
            expects_workflow_result: selects(&feed, node),
            floor,
            revision,
            snapshot,
        }));
    }
    Ok(None)
}

fn selects(feed: &FactFeed, node: &str) -> bool {
    (feed.workflow_choice && node == feed.root)
        || feed.workflow_selectors.iter().any(|row| row[0] == node)
}

pub(crate) struct WorkflowFacts {
    pub(crate) feed: FactFeed,
    pub(crate) floor: u64,
    pub(crate) snapshot: String,
    pub(crate) available: Vec<String>,
}

/// Read the exact deployed topology and availability in one observation.
pub(crate) fn observe_workflow<'a>(
    c: &Connection,
    family: &str,
    successor: &str,
    nodes: impl IntoIterator<Item = &'a str>,
) -> Result<WorkflowFacts> {
    let (record, floor, snapshot, revision, pending, unavailable) = maybe_current(
        c,
        "SELECT record,floor,snapshot,revision,pending IS NOT NULL,unavailable
         FROM main.hard_fact_feed WHERE singleton=1 AND family=?1",
        params![family.to_owned()],
        |row| {
            Ok((
                row.get::<String>(0)?,
                integer(row, 1)?,
                row.get::<String>(2)?,
                integer(row, 3)?,
                row.get::<bool>(4)?,
                row.get::<String>(5)?,
            ))
        },
    )
    .map_err(db)?
    .ok_or(Error::Conflict("Session fact scope changed"))?;
    let feed: FactFeed = decode(record.as_bytes())?;
    if feed.family != family || feed.workflow_predecessors(successor).is_empty() {
        return Err(Error::Conflict("Session fact cut unavailable"));
    }
    let mut available = Vec::new();
    if revision != 0 && !pending {
        let unavailable: BTreeSet<String> = decode(unavailable.as_bytes())?;
        available.extend(
            nodes
                .into_iter()
                .filter(|node| !unavailable.contains(*node))
                .map(str::to_owned),
        );
    }
    if !available.is_empty() {
        match source_authority::current(c) {
            Ok(authority) if authority.as_ref() == Some(&feed.authority) => {}
            Ok(_) | Err(Error::Conflict(_)) => available.clear(),
            Err(error) => return Err(error),
        }
    }
    Ok(WorkflowFacts {
        feed,
        floor,
        snapshot,
        available,
    })
}

pub(crate) fn is_workflow_selector(c: &Connection, family: &str, node: &str) -> Result<bool> {
    Ok(head(c)?.is_some_and(|head| head.feed.family == family && selects(&head.feed, node)))
}

pub(crate) fn nested_feed(c: &Connection, family: &str) -> Result<Option<FactFeed>> {
    Ok(head(c)?
        .map(|head| head.feed)
        .filter(|feed| feed.family == family && !feed.workflow_selectors.is_empty()))
}

pub(crate) fn choice_nodes(c: &Connection, family: &str) -> Result<Option<[String; 4]>> {
    Ok(head(c)?
        .filter(|head| head.feed.family == family)
        .and_then(|head| head.feed.choice_nodes().cloned()))
}

/// The edge is independently deployed. A fact observation cannot add one.
pub(crate) fn workflow_cut(
    c: &Connection,
    family: &str,
    node: &str,
) -> Result<Option<(Vec<String>, u64, String)>> {
    let Some(head) = head(c)? else {
        return Ok(None);
    };
    let predecessors = head.feed.workflow_predecessors(node);
    if predecessors.is_empty() {
        return Ok(None);
    }
    let matching = head.feed.family == family || crate::persistence::one_current(
        c,
        "SELECT EXISTS(SELECT 1 FROM main.family_origins own JOIN main.family_origins alias ON own.origin=alias.origin WHERE own.family=?1 AND alias.family=?2)",
        params![head.feed.family.clone(), family.to_owned()],
        |row| row.get(0),
    ).map_err(db)?;
    if !matching {
        return Ok(None);
    }
    if head.feed.family != family {
        return Err(Error::Conflict("workflow requires the original family"));
    }
    Ok(Some((
        predecessors.into_iter().map(str::to_owned).collect(),
        head.floor,
        head.snapshot,
    )))
}

fn bound_intent(
    c: &Connection,
    operation_id: &str,
) -> Result<Option<(FactIntent, FactBarrier, Option<FactResolution>)>> {
    let row = maybe_current(
        c,
        "SELECT original,barrier,resolution FROM main.hard_fact_intents WHERE operation_id=?1",
        params![operation_id.to_owned()],
        |row| {
            Ok((
                row.get::<String>(0)?,
                row.get::<String>(1)?,
                row.get::<Option<String>>(2)?,
            ))
        },
    )
    .map_err(db)?;
    row.map(|(original, barrier, resolution)| {
        Ok((
            decode(original.as_bytes())?,
            decode(barrier.as_bytes())?,
            resolution
                .map(|encoded| decode(encoded.as_bytes()))
                .transpose()?,
        ))
    })
    .transpose()
}

fn tail(c: &Connection, head: &Head) -> Result<Option<FactBarrier>> {
    head.pending
        .as_deref()
        .map(|operation_id| {
            let (_, barrier, resolution) = bound_intent(c, operation_id)?
                .ok_or(Error::Conflict("hard fact pending tail missing"))?;
            if resolution.is_some()
                || barrier.floor != head.floor
                || barrier.revision <= head.revision
            {
                return Err(Error::Conflict("hard fact pending tail changed"));
            }
            Ok(barrier)
        })
        .transpose()
}

fn pending_prefix(installed: &str, tail: &FactBarrier) -> Result<String> {
    Ok(body_digest(&serde_json::to_string(&(
        "weaver.hard-fact-membership.v1",
        installed,
        &tail.pending_prefix,
    ))?))
}

fn preparation(
    c: &Connection,
    caller: Option<&SourceIdentity>,
    barrier: &FactBarrier,
) -> Result<FactPreparation> {
    let head = head(c)?.ok_or(Error::Denied)?;
    authorize(c, caller, &head.feed)?;
    let (intent, original, resolution) = bound_intent(c, &barrier.operation_id)?
        .ok_or(Error::Conflict("hard fact intent missing"))?;
    if original != *barrier {
        return Err(Error::Conflict("hard fact barrier binding"));
    }
    if let Some(resolution) = resolution {
        return Ok(FactPreparation::Resolved(resolution));
    }
    let tail = tail(c, &head)?.ok_or(Error::Conflict("hard fact pending prefix missing"))?;
    if head.revision.checked_add(1) != Some(barrier.revision)
        || head.snapshot != intent.previous_snapshot
        || intent.snapshot()? != barrier.snapshot
        || intent.source_epoch != head.feed.authority.epoch
        || barrier.floor > tail.floor
    {
        return Err(Error::Conflict("hard fact source cut changed"));
    }
    Ok(FactPreparation::Pending(FactWork {
        barrier: original,
        expected_floor: tail.floor,
        pending_prefix: pending_prefix(&head.snapshot, &tail)?,
        root: head.feed.root,
        dependencies: head.feed.dependencies,
        available: intent.available,
    }))
}

fn next_barrier(
    connection: &Connection,
    head: &Head,
    intent: &FactIntent,
    snapshot: String,
) -> Result<FactBarrier> {
    let tail = tail(connection, head)?;
    let (previous_revision, previous_snapshot, previous_prefix) = match &tail {
        Some(tail) => (tail.revision, &tail.snapshot, tail.pending_prefix.as_str()),
        None => (head.revision, &head.snapshot, GENESIS),
    };
    if intent.domain != head.feed.domain
        || intent.source_epoch != head.feed.authority.epoch
        || intent.expected_floor != head.floor
        || previous_revision.checked_add(1) != Some(intent.revision)
        || &intent.previous_snapshot != previous_snapshot
        || previous_revision.saturating_sub(head.revision) >= MAX_PENDING
    {
        return Err(Error::Conflict("hard fact predecessor changed"));
    }
    let task = crate::stream_state::task(connection, &head.feed.family)?;
    if !task.nodes.contains(&head.feed.root)
        || head
            .feed
            .dependencies
            .iter()
            .any(|(a, b)| !task.nodes.contains(a) || !task.nodes.contains(b))
        || head.feed.workflow.as_ref().is_some_and(|edge| {
            !task.nodes.contains(&edge.predecessor) || !task.nodes.contains(&edge.successor)
        })
        || head
            .feed
            .workflow_path
            .iter()
            .any(|node| !task.nodes.contains(node))
    {
        return Err(Error::Invalid("hard fact graph outside original task"));
    }
    let floor = head.floor + 1;
    let pending_prefix = body_digest(&serde_json::to_string(&(
        "weaver.hard-fact-prefix.v1",
        &head.feed,
        floor,
        previous_prefix,
        &snapshot,
    ))?);
    Ok(FactBarrier {
        operation_id: intent.operation_id.clone(),
        source_epoch: intent.source_epoch,
        revision: intent.revision,
        snapshot,
        floor,
        pending_prefix,
    })
}

impl Ledger {
    /// Trusted startup configuration. A previously installed feed may not be removed or retargeted.
    pub fn configure_fact_feed(&mut self, requested: Option<&FactFeed>) -> Result<()> {
        if let Some(feed) = requested {
            feed.validate()?;
        }
        let tx = begin(&mut self.connection).map_err(db)?;
        match (head(&tx)?, requested) {
            (None, None) => {}
            (Some(head), Some(feed)) if head.feed == *feed => {}
            (None, Some(feed)) => {
                if let Some(authority) = source_authority::current(&tx)?
                    && authority != feed.authority
                {
                    return Err(Error::Denied);
                }
                exec(
                    &tx,
                    "INSERT INTO main.hard_fact_feed VALUES(1,?1,?2,0,0,?3,NULL,'[]')",
                    params![
                        feed.family.clone(),
                        serde_json::to_string(feed)?,
                        GENESIS.to_owned()
                    ],
                )
                .map_err(db)?;
            }
            _ => return Err(Error::Conflict("hard fact feed deployment changed")),
        }
        tx.commit().map_err(db)
    }

    /// Observe the installed cut and the exact ordered barriers for source recovery.
    pub fn inspect_fact_feed(&mut self) -> Result<FactFeedState> {
        let tx = begin(&mut self.connection).map_err(db)?;
        let head = head(&tx)?.ok_or(Error::Denied)?;
        authorize(&tx, self.source.as_ref(), &head.feed)?;
        let available = if head.revision == 0 {
            None
        } else {
            Some(
                crate::persistence::one_current(
                    &tx,
                    "SELECT NOT EXISTS(SELECT 1 FROM json_each(unavailable) WHERE value=?1)
                 FROM main.hard_fact_feed WHERE singleton=1",
                    params![head.feed.root.clone()],
                    |row| row.get::<bool>(0),
                )
                .map_err(db)?,
            )
        };
        let mut pending = Vec::new();
        if let Some(tail) = tail(&tx, &head)? {
            let rows = read_all_current(
                &tx,
                "SELECT original,barrier FROM main.hard_fact_intents
                 WHERE resolution IS NULL LIMIT ?1",
                params![(MAX_PENDING + 1) as i64],
                |row| Ok((row.get::<String>(0)?, row.get::<String>(1)?)),
            )
            .map_err(db)?;
            let mut entries = rows
                .into_iter()
                .map(|(intent, barrier)| {
                    Ok((
                        decode::<FactIntent>(intent.as_bytes())?,
                        decode::<FactBarrier>(barrier.as_bytes())?,
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            entries.sort_unstable_by_key(|(_, barrier)| barrier.revision);
            if entries.len() as u64 != tail.revision - head.revision
                || entries.last().map(|(_, barrier)| barrier) != Some(&tail)
            {
                return Err(Error::Conflict("hard fact pending sequence changed"));
            }
            let mut revision = head.revision;
            let mut snapshot = head.snapshot.as_str();
            for (intent, barrier) in &entries {
                if revision.checked_add(1) != Some(barrier.revision)
                    || snapshot != intent.previous_snapshot
                    || intent.snapshot()? != barrier.snapshot
                    || intent.operation_id != barrier.operation_id
                    || intent.revision != barrier.revision
                    || intent.source_epoch != head.feed.authority.epoch
                    || intent.source_epoch != barrier.source_epoch
                    || intent.domain != head.feed.domain
                {
                    return Err(Error::Conflict("hard fact pending sequence changed"));
                }
                revision = barrier.revision;
                snapshot = &barrier.snapshot;
                pending.push((barrier.clone(), intent.available));
            }
        }
        tx.commit().map_err(db)?;
        Ok(FactFeedState {
            domain: head.feed.domain,
            source_epoch: head.feed.authority.epoch,
            floor: head.floor,
            revision: head.revision,
            snapshot: head.snapshot,
            available,
            pending,
        })
    }

    /// Stage the exact original and install the pending barrier before a worker sees the intent.
    pub fn stage_fact_intent(&mut self, intent: &FactIntent) -> Result<FactBarrier> {
        let snapshot = intent.snapshot()?;
        let tx = begin(&mut self.connection).map_err(db)?;
        let head = head(&tx)?.ok_or(Error::Denied)?;
        authorize(&tx, self.source.as_ref(), &head.feed)?;
        if let Some((original, barrier, _)) = bound_intent(&tx, &intent.operation_id)? {
            if original != *intent {
                return Err(Error::Conflict("hard fact intent identity reused"));
            }
            return Ok(barrier);
        }
        let barrier = next_barrier(&tx, &head, intent, snapshot)?;
        exec(
            &tx,
            "INSERT INTO main.hard_fact_intents VALUES(?1,?2,?3,NULL)",
            params![
                intent.operation_id.clone(),
                serde_json::to_string(intent)?,
                serde_json::to_string(&barrier)?
            ],
        )
        .map_err(db)?;
        exec(
            &tx,
            "UPDATE main.hard_fact_feed SET floor=?1,pending=?2 WHERE singleton=1",
            params![barrier.floor as i64, intent.operation_id.clone()],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(barrier)
    }

    pub fn prepare_fact_projection(&mut self, barrier: &FactBarrier) -> Result<FactPreparation> {
        let tx = begin(&mut self.connection).map_err(db)?;
        let result = preparation(&tx, self.source.as_ref(), barrier)?;
        tx.commit().map_err(db)?;
        Ok(result)
    }

    /// Only the trusted native derivation owner calls this. The RPC accepts no projection rows.
    pub fn resolve_fact_projection(
        &mut self,
        work: &FactWork,
        affected: Vec<String>,
    ) -> Result<FactResolution> {
        let tx = begin(&mut self.connection).map_err(db)?;
        match preparation(&tx, self.source.as_ref(), &work.barrier)? {
            FactPreparation::Pending(exact) if exact == *work => {}
            FactPreparation::Resolved(original) if original.affected == affected => {
                return Ok(original);
            }
            _ => return Err(Error::Conflict("hard fact projection input changed")),
        }
        if affected.is_empty()
            || affected.len() > 65
            || !affected.contains(&work.root)
            || affected.windows(2).any(|pair| pair[0] >= pair[1])
            || affected.iter().any(|node| {
                node != &work.root
                    && !work
                        .dependencies
                        .iter()
                        .any(|(dependent, _)| dependent == node)
            })
            || work.dependencies.iter().any(|(dependent, dependency)| {
                affected.binary_search(dependency).is_ok()
                    && affected.binary_search(dependent).is_err()
            })
        {
            return Err(Error::Invalid("invalid hard fact impact"));
        }
        let barrier = &work.barrier;
        let head = head(&tx)?.ok_or(Error::Conflict("hard fact feed missing"))?;
        let remaining = tail(&tx, &head)?.filter(|tail| tail.operation_id != barrier.operation_id);
        let remaining_pending_prefix = remaining
            .as_ref()
            .map(|tail| pending_prefix(&barrier.snapshot, tail))
            .transpose()?;
        let unavailable = if work.available {
            "[]".to_owned()
        } else {
            serde_json::to_string(&affected)?
        };
        let resolution = FactResolution {
            barrier: barrier.clone(),
            affected,
            floor: work.expected_floor,
            previous_pending_prefix: work.pending_prefix.clone(),
            remaining_pending_prefix,
        };
        exec(&tx, "UPDATE main.hard_fact_feed SET revision=?1,snapshot=?2,pending=?3,unavailable=?4 WHERE singleton=1",
            params![barrier.revision as i64, barrier.snapshot.clone(), remaining.map(|tail| tail.operation_id), unavailable]).map_err(db)?;
        exec(
            &tx,
            "UPDATE main.hard_fact_intents SET resolution=?1 WHERE operation_id=?2",
            params![
                serde_json::to_string(&resolution)?,
                barrier.operation_id.clone()
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(resolution)
    }
}
