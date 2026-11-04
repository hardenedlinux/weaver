// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Atomic publication, holds, consumption and serialized dispatch guard.
use crate::persistence::{Session, WriteScope};
use std::path::Path;
use weaver_contracts::{Error, Outcome, Proposal, Receipt, Result, Task};

pub(crate) fn db(e: crate::persistence::Error) -> Error {
    Error::Storage(e.to_string())
}

/// Single deciding store for policy, original tasks, holds and execution.
pub struct Ledger {
    pub(crate) connection: Session,
    pub(crate) session: String,
    pub(crate) source: Option<weaver_contracts::SourceIdentity>,
}

/// Unforgeable within the public API, deliberately not Clone or serializable.
pub struct Dispatch {
    proposal: Proposal,
    session: String,
    domains: weaver_contracts::DomainStamp,
}

impl Ledger {
    /// Statistical intervals only; no execution, settlement or recovery authority.
    pub fn transaction_timings(&self) -> crate::persistence::TransactionTimings {
        self.connection.timings()
    }
    /// Explicit resource completion; errors cannot count as successful native drain.
    pub fn close(self) -> Result<()> {
        self.connection.close().map_err(db)
    }
    /// Reuse requires no unresolved explicit transaction; this is not an authorization check.
    pub fn require_quiescent(&self) -> Result<()> {
        if self.connection.require_quiescent().is_err() {
            return Err(Error::Conflict("ledger transaction still unresolved"));
        }
        Ok(())
    }
    /// Open a single-host deciding store with full synchronous WAL durability.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let mut connection = Session::open(path).map_err(db)?;
        connection.initialize_ledger().map_err(db)?;
        // A missing retained manifest cannot be reconstructed from outcome rows.
        // Older images require explicit authoritative recovery, never backfill.
        let _: Vec<String> = crate::persistence::read_all(
            &connection,
            "SELECT reservations FROM execution_claims LIMIT 0",
            (),
            |r| r.get(0),
        )
        .map_err(db)?;
        let session: String =
            crate::persistence::one(&connection, "SELECT lower(hex(randomblob(32)))", (), |r| {
                r.get(0)
            })
            .map_err(db)?;
        Ok(Self {
            connection,
            session,
            source: None,
        })
    }

    /// Trusted publication CAS. It cannot be called through the adapter wire protocol.
    pub fn publish(
        &mut self,
        expected_revision: Option<u64>,
        policy: &str,
        fence: u64,
    ) -> Result<u64> {
        weaver_policy::validate(policy)?;
        self.update_authority(crate::publication::AuthorityChange {
            expected: expected_revision,
            policy,
            schema: None,
            fence,
        })
    }

    /// Register or recover the exact immutable original task.
    pub fn register_task(&mut self, task: &Task) -> Result<()> {
        self.register_task_binding(task, None, None)
    }

    /// Staged control tasks cannot execute before their original publication commits.
    pub fn register_published_task(
        &mut self,
        task: &Task,
        key: &weaver_contracts::PublicationKey,
    ) -> Result<()> {
        self.register_task_binding(task, Some(key), None)
    }

    pub(crate) fn register_task_binding(
        &mut self,
        task: &Task,
        key: Option<&weaver_contracts::PublicationKey>,
        domains: Option<&weaver_contracts::DomainBinding>,
    ) -> Result<()> {
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        crate::task_origins::default_binding(&tx, task, domains, key)?;
        register_task_in(&tx, task, key, domains)?;
        tx.commit().map_err(db)?;
        Ok(())
    }
}

pub(crate) fn register_task_in(
    tx: &WriteScope<'_>,
    task: &Task,
    key: Option<&weaver_contracts::PublicationKey>,
    domains: Option<&weaver_contracts::DomainBinding>,
) -> Result<()> {
    task.validate()?;
    crate::metering::require_task_quotes(tx, task)?;
    let record = serde_json::to_string(task)?;
    crate::domains::bind(tx, task, domains)?;
    if let Some(profile) = &task.provider_profile {
        crate::provider_profiles::register(tx, profile)?;
    }
    let old: Option<String> = crate::persistence::maybe(
        tx,
        "SELECT record FROM tasks WHERE family=?1",
        crate::persistence::params![task.family.to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    match old {
        Some(value) => {
            let original: Task = weaver_contracts::decode(value.as_bytes())?;
            if original != *task {
                return Err(Error::Conflict("original task is immutable"));
            }
        }
        None => {
            crate::persistence::exec(
                tx,
                "INSERT INTO tasks(family,record,budget) VALUES(?1,?2,?3)",
                crate::persistence::params![
                    (task.family).to_owned(),
                    (record).to_owned(),
                    (task.budget as i64).to_owned()
                ],
            )
            .map_err(db)?;
        }
    }
    crate::task_publication::bind(tx, &task.family, key)?;
    crate::task_origins::seal_publication(tx, &task.family)?;
    Ok(())
}

impl Ledger {
    /// Queue publication never calls a transport. Lost replies recover the same digest.
    pub fn enqueue(&mut self, proposal: &Proposal) -> Result<Receipt> {
        let digest = proposal.digest()?;
        let tx =
            crate::persistence::begin_family(&mut self.connection, &proposal.family).map_err(db)?;
        if let Some(old) = receipt(&tx, &proposal.family, &proposal.node)? {
            if old.digest != digest {
                return Err(Error::Conflict("logical key already bound"));
            }
            return Ok(old);
        }
        guard(&tx, proposal)?;
        crate::execution_exposure::require_family(&tx, &proposal.family)?;
        let kind: Option<String> = crate::persistence::maybe(
            &tx,
            "SELECT kind FROM execution_claims WHERE family=?1 AND node=?2",
            crate::persistence::params![proposal.family.to_owned(), proposal.node.to_owned()],
            |r| r.get(0),
        )
        .map_err(db)?;
        if kind.is_some() {
            return Err(Error::Conflict(
                "logical node already claimed without original operation",
            ));
        }
        crate::execution_exposure::retain(
            &tx,
            crate::execution_exposure::ReservationClaim {
                family: &proposal.family,
                node: &proposal.node,
                kind: crate::execution_exposure::ClaimKind::Request,
                member: "",
                digest: &digest,
                ceiling: proposal.ceiling,
            },
        )?;
        let updated = crate::persistence::exec(
            &tx,
            "UPDATE tasks SET held=held+?1 WHERE family=?2 AND ?1<=budget-held",
            crate::persistence::params![
                (proposal.ceiling as i64).to_owned(),
                (proposal.family).to_owned()
            ],
        )
        .map_err(db)?;
        if updated != 1 {
            return Err(Error::Conflict("shared budget exhausted"));
        }
        crate::persistence::exec(
            &tx,
            "INSERT INTO operations VALUES(?1,?2,?3,?4,?5,'queued')",
            crate::persistence::params![
                (proposal.family).to_owned(),
                (proposal.node).to_owned(),
                (digest).to_owned(),
                (serde_json::to_string(proposal)?).to_owned(),
                (proposal.ceiling as i64).to_owned()
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        self.lookup(&proposal.family, &proposal.node)?
            .ok_or(Error::Conflict("committed outcome missing"))
    }

    /// Durable consumption precedes any possible external call. Crash means unknown.
    pub fn consume(&mut self, family: &str, node: &str) -> Result<Dispatch> {
        let tx = crate::persistence::begin_family(&mut self.connection, family).map_err(db)?;
        let body: Option<String> = crate::persistence::maybe(
            &tx,
            "SELECT proposal FROM operations WHERE family=?1 AND node=?2 AND state='queued'",
            crate::persistence::params![(family).to_owned(), (node).to_owned()],
            |r| r.get(0),
        )
        .map_err(db)?;
        let p: Proposal =
            serde_json::from_str(&body.ok_or(Error::Conflict("not queued or already consumed"))?)?;
        guard(&tx, &p)?;
        crate::execution_exposure::request(&tx, &p)?;
        crate::persistence::exec(
            &tx,
            "UPDATE operations SET state='unknown' WHERE family=?1 AND node=?2",
            crate::persistence::params![(family).to_owned(), (node).to_owned()],
        )
        .map_err(db)?;
        let domains = crate::domains::stamp(&tx, family)?;
        tx.commit().map_err(db)?;
        Ok(Dispatch {
            proposal: p,
            session: self.session.clone(),
            domains,
        })
    }

    /// Hold the same deciding write lock through the synchronous bounded send.
    /// Publications/owner changes take effect only after this transaction releases.
    /// Never call this with an unbounded or reentrant callback.
    pub fn dispatch<T>(
        &mut self,
        permit: Dispatch,
        send: impl FnOnce(&Proposal) -> T,
    ) -> Result<T> {
        if permit.session != self.session {
            return Err(Error::Conflict("foreign ledger handle"));
        }
        let p = permit.proposal;
        let tx = crate::persistence::begin_family(&mut self.connection, &p.family).map_err(db)?;
        crate::domains::require_stamp(&tx, &p.family, &permit.domains)?;
        guard(&tx, &p)?;
        crate::execution_exposure::request(&tx, &p)?;
        let old =
            receipt(&tx, &p.family, &p.node)?.ok_or(Error::Conflict("consumption missing"))?;
        if old.digest != p.digest()? || old.outcome != Outcome::Unknown {
            return Err(Error::Conflict("consumption changed"));
        }
        let result = send(&p);
        // Never refund here: even a successful response is not authenticated final usage.
        tx.commit().map_err(db)?;
        Ok(result)
    }

    /// Recover the original outcome without creating new execution authority.
    pub fn lookup(&self, family: &str, node: &str) -> Result<Option<Receipt>> {
        receipt(&self.connection, family, node)
    }
    /// Read retained capacity, including all unknown executions.
    pub fn held(&self, family: &str) -> Result<u64> {
        crate::persistence::one(
            &self.connection,
            "SELECT held FROM tasks WHERE family=?1",
            crate::persistence::params![(family).to_owned()],
            |r| integer(r, 0),
        )
        .map_err(db)
    }
}

fn receipt(
    connection: &crate::persistence::driver::Connection,
    family: &str,
    node: &str,
) -> Result<Option<Receipt>> {
    crate::persistence::maybe(
        connection,
        "SELECT digest,state,reserved FROM operations WHERE family=?1 AND node=?2",
        crate::persistence::params![(family).to_owned(), (node).to_owned()],
        |r| {
            let state: String = r.get(1)?;
            Ok(Receipt {
                family: family.into(),
                node: node.into(),
                digest: r.get(0)?,
                reserved: integer(r, 2)?,
                outcome: match state.as_str() {
                    "queued" => Outcome::Queued,
                    "response_received" => Outcome::ResponseReceived,
                    _ => Outcome::Unknown,
                },
            })
        },
    )
    .map_err(db)
}

fn guard(tx: &WriteScope<'_>, p: &Proposal) -> Result<()> {
    crate::publication_barrier::require_resolved(tx)?;
    crate::task_publication::require(tx, &p.family)?;
    let (revision, fence, policy): (u64, u64, String) = crate::persistence::one(
        tx,
        "SELECT revision,fence,policy FROM authority WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, integer(r, 1)?, r.get(2)?)),
    )
    .map_err(db)?;
    if revision != p.revision || fence != p.fence {
        return Err(Error::Conflict(
            "stale policy/history revision or owner fence",
        ));
    }
    let record: String = crate::persistence::one(
        tx,
        "SELECT record FROM tasks WHERE family=?1",
        crate::persistence::params![p.family.to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    let task: Task = serde_json::from_str(&record)?;
    if !task.admits(p) {
        return Err(Error::Denied);
    }
    weaver_policy::authorize(&policy, &task, p)
}

pub(crate) fn integer(
    row: &crate::persistence::Row,
    index: usize,
) -> crate::persistence::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|e| crate::persistence::Error::ConversionFailure(e.to_string()))
}
