//! Atomic publication, holds, consumption and serialized dispatch guard.
use crate::schema::SCHEMA;
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior};
use std::{path::Path, time::Duration};
use weaver_contracts::{Error, Outcome, Proposal, Receipt, Result, Task};

pub(crate) fn db(e: rusqlite::Error) -> Error {
    Error::Storage(e.to_string())
}

/// Single deciding store for policy, original tasks, holds and execution.
pub struct Ledger {
    pub(crate) connection: Connection,
    pub(crate) session: String,
}

/// Unforgeable within the public API, deliberately not Clone or serializable.
pub struct Dispatch {
    proposal: Proposal,
    session: String,
}

impl Ledger {
    /// Explicit resource completion; errors cannot count as successful native drain.
    pub fn close(self) -> Result<()> {
        self.connection
            .close()
            .map_err(|(_connection, error)| db(error))
    }
    /// Reuse requires no unresolved explicit transaction; this is not an authorization check.
    pub fn require_quiescent(&self) -> Result<()> {
        if !self.connection.is_autocommit() {
            return Err(Error::Conflict("ledger transaction still unresolved"));
        }
        Ok(())
    }
    /// Open a single-host deciding store with full synchronous WAL durability.
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let connection = Connection::open(path).map_err(db)?;
        connection
            .busy_timeout(Duration::from_secs(10))
            .map_err(db)?;
        connection
            .execute_batch(
                "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
            )
            .map_err(db)?;
        connection.execute_batch(SCHEMA).map_err(db)?;
        let session: String = connection
            .query_row("SELECT lower(hex(randomblob(32)))", [], |r| r.get(0))
            .map_err(db)?;
        Ok(Self {
            connection,
            session,
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
        task.validate()?;
        let record = serde_json::to_string(task)?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        let old: Option<String> = tx
            .query_row(
                "SELECT record FROM tasks WHERE family=?1",
                [&task.family],
                |r| r.get(0),
            )
            .optional()
            .map_err(db)?;
        match old {
            Some(value) if value != record => {
                return Err(Error::Conflict("original task is immutable"));
            }
            Some(_) => (),
            None => {
                tx.execute(
                    "INSERT INTO tasks(family,record,budget) VALUES(?1,?2,?3)",
                    rusqlite::params![task.family, record, task.budget as i64],
                )
                .map_err(db)?;
            }
        }
        tx.commit().map_err(db)?;
        Ok(())
    }

    /// Queue publication never calls a transport. Lost replies recover the same digest.
    pub fn enqueue(&mut self, proposal: &Proposal) -> Result<Receipt> {
        let digest = proposal.digest()?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        if let Some(old) = receipt(&tx, &proposal.family, &proposal.node)? {
            if old.digest != digest {
                return Err(Error::Conflict("logical key already bound"));
            }
            return Ok(old);
        }
        guard(&tx, proposal)?;
        let kind: Option<String> = tx
            .query_row(
                "SELECT kind FROM execution_claims WHERE family=?1 AND node=?2",
                [&proposal.family, &proposal.node],
                |r| r.get(0),
            )
            .optional()
            .map_err(db)?;
        if kind.is_some_and(|k| k != "request") {
            return Err(Error::Conflict("logical node already claimed by stream"));
        }
        tx.execute(
            "INSERT OR IGNORE INTO execution_claims VALUES(?1,?2,'request')",
            [&proposal.family, &proposal.node],
        )
        .map_err(db)?;
        let updated = tx
            .execute(
                "UPDATE tasks SET held=held+?1 WHERE family=?2 AND ?1<=budget-held",
                rusqlite::params![proposal.ceiling as i64, proposal.family],
            )
            .map_err(db)?;
        if updated != 1 {
            return Err(Error::Conflict("shared budget exhausted"));
        }
        tx.execute(
            "INSERT INTO operations VALUES(?1,?2,?3,?4,?5,'queued')",
            rusqlite::params![
                proposal.family,
                proposal.node,
                digest,
                serde_json::to_string(proposal)?,
                proposal.ceiling as i64
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        self.lookup(&proposal.family, &proposal.node)?
            .ok_or(Error::Conflict("committed outcome missing"))
    }

    /// Durable consumption precedes any possible external call. Crash means unknown.
    pub fn consume(&mut self, family: &str, node: &str) -> Result<Dispatch> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        let body: Option<String> = tx
            .query_row(
                "SELECT proposal FROM operations WHERE family=?1 AND node=?2 AND state='queued'",
                [family, node],
                |r| r.get(0),
            )
            .optional()
            .map_err(db)?;
        let p: Proposal =
            serde_json::from_str(&body.ok_or(Error::Conflict("not queued or already consumed"))?)?;
        guard(&tx, &p)?;
        tx.execute(
            "UPDATE operations SET state='unknown' WHERE family=?1 AND node=?2",
            [family, node],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(Dispatch {
            proposal: p,
            session: self.session.clone(),
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
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        guard(&tx, &p)?;
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
        self.connection
            .query_row("SELECT held FROM tasks WHERE family=?1", [family], |r| {
                integer(r, 0)
            })
            .map_err(db)
    }
}

fn receipt(connection: &Connection, family: &str, node: &str) -> Result<Option<Receipt>> {
    connection
        .query_row(
            "SELECT digest,state,reserved FROM operations WHERE family=?1 AND node=?2",
            [family, node],
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
        .optional()
        .map_err(db)
}

fn guard(tx: &Transaction<'_>, p: &Proposal) -> Result<()> {
    let (revision, fence, policy): (u64, u64, String) = tx
        .query_row(
            "SELECT revision,fence,policy FROM authority WHERE singleton=1",
            [],
            |r| Ok((integer(r, 0)?, integer(r, 1)?, r.get(2)?)),
        )
        .map_err(db)?;
    if revision != p.revision || fence != p.fence {
        return Err(Error::Conflict(
            "stale policy/history revision or owner fence",
        ));
    }
    let record: String = tx
        .query_row(
            "SELECT record FROM tasks WHERE family=?1",
            [&p.family],
            |r| r.get(0),
        )
        .map_err(db)?;
    let task: Task = serde_json::from_str(&record)?;
    if !task.admits(p) {
        return Err(Error::Denied);
    }
    weaver_policy::authorize(&policy, &task, p)
}

pub(crate) fn integer(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value: i64 = row.get(index)?;
    u64::try_from(value).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            index,
            rusqlite::types::Type::Integer,
            Box::new(e),
        )
    })
}
