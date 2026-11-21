// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Host-owned connection configuration, on the existing deciding store.
//! A durable receipt is historical; only the current head selects a profile.
use crate::{
    Ledger,
    persistence::{self, driver::Connection},
    store::{db, integer},
};
use serde::{Deserialize, Serialize};
use weaver_contracts::{Error, Result, body_digest, identifier};

/// Local HTTP operation binding. It contains a fingerprint, never a token or
/// provider/source authority. Server admission still validates realm separation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionProfile {
    pub session: String,
    pub token_sha256: [u8; 32],
}
/// Immutable host request; None retires a connection without deleting its clock.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionChange {
    pub operation_id: String,
    pub connection: String,
    pub expected_revision: Option<u64>,
    pub profile: Option<ConnectionProfile>,
}
impl ConnectionChange {
    fn validate(&self) -> Result<()> {
        identifier(&self.operation_id)?;
        identifier(&self.connection)?;
        if self.expected_revision.is_some_and(|n| n >= i64::MAX as u64) {
            return Err(Error::Invalid("connection revision"));
        }
        if let Some(p) = &self.profile {
            identifier(&p.session)?;
            if p.token_sha256 == [0; 32] {
                return Err(Error::Invalid("connection credential fingerprint"));
            }
        }
        Ok(())
    }
    fn encoded(&self) -> Result<(String, String)> {
        self.validate()?;
        let raw = serde_json::to_string(self)?;
        Ok((body_digest(&raw), raw))
    }
}
/// Immutable operation reference; the digest binds its entire prepared request.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionKey {
    pub operation_id: String,
    pub digest: String,
}
/// Durable decision. Temporary listener custody conflicts leave no decision.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConnectionOutcome {
    Committed,
    Rejected,
    Aborted,
}
/// Historical outcome, not permission to activate its old profile.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionReceipt {
    pub key: ConnectionKey,
    pub outcome: ConnectionOutcome,
    pub revision: Option<u64>,
}
/// Current committed snapshot. A retired profile retains its monotone revision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConnectionHead {
    pub revision: u64,
    pub key: ConnectionKey,
    pub profile: Option<ConnectionProfile>,
}

/// Runtime custody of one immutable committed connection. Publishing another
/// generation requires every live listener to drain and release this lease.
pub struct ConnectionLease {
    head: ConnectionHead,
    connection: String,
    owner: std::sync::Arc<crate::persistence::owner::Owner>,
}
impl ConnectionLease {
    /// Immutable snapshot held until this listener's custody is released.
    pub fn head(&self) -> &ConnectionHead {
        &self.head
    }
}
impl Drop for ConnectionLease {
    fn drop(&mut self) {
        if let Ok(mut leases) = self.owner.connection_leases.lock()
            && let Some(count) = leases.get_mut(&self.connection)
        {
            *count -= 1;
            if *count == 0 {
                leases.remove(&self.connection);
            }
        }
    }
}

fn head(c: &Connection, id: &str) -> Result<Option<ConnectionHead>> {
    let row: Option<(u64, String, String, String)> = persistence::maybe(
        c,
        "SELECT revision,operation_id,digest,record FROM connection_heads WHERE id=?1",
        persistence::params![id.to_owned()],
        |r| Ok((integer(r, 0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
    )
    .map_err(db)?;
    row.map(|(revision, operation_id, digest, raw)| {
        let change: ConnectionChange = weaver_contracts::decode(raw.as_bytes())?;
        if revision != change.expected_revision.map_or(0, |r| r + 1)
            || change.connection != id
            || change.operation_id != operation_id
            || change.encoded()?.0 != digest
        {
            return Err(Error::Conflict("connection head binding"));
        }
        Ok(ConnectionHead {
            revision,
            key: ConnectionKey {
                operation_id,
                digest,
            },
            profile: change.profile,
        })
    })
    .transpose()
}
fn request(
    c: &Connection,
    key: &ConnectionKey,
) -> Result<Option<(ConnectionChange, Option<ConnectionReceipt>)>> {
    identifier(&key.operation_id)?;
    if key.digest.len() != 64
        || !key
            .digest
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Err(Error::Invalid("connection operation digest"));
    }
    let row: Option<(String, String, Option<String>)> = persistence::maybe(
        c,
        "SELECT digest,request,receipt FROM connection_updates WHERE operation_id=?1",
        persistence::params![key.operation_id.clone()],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )
    .map_err(db)?;
    row.map(|(digest, raw, receipt)| {
        let change: ConnectionChange = weaver_contracts::decode(raw.as_bytes())?;
        if digest != key.digest
            || change.operation_id != key.operation_id
            || change.encoded()?.0 != digest
        {
            return Err(Error::Conflict("connection operation already bound"));
        }
        let receipt: Option<ConnectionReceipt> = receipt
            .map(|r| weaver_contracts::decode(r.as_bytes()))
            .transpose()?;
        if receipt.as_ref().is_some_and(|r| {
            r.key != *key
                || r.revision.is_some_and(|n| n > i64::MAX as u64)
                || (r.outcome == ConnectionOutcome::Committed
                    && r.revision != Some(change.expected_revision.map_or(0, |n| n + 1)))
                || (r.outcome == ConnectionOutcome::Rejected
                    && r.revision == change.expected_revision)
        }) {
            return Err(Error::Conflict("connection receipt binding"));
        }
        Ok((change, receipt))
    })
    .transpose()
}
impl Ledger {
    fn require_connection_host(&self) -> Result<()> {
        if self.source.is_some() {
            return Err(Error::Denied);
        }
        Ok(())
    }
    /// Prepare in the same durable ledger. Exact retries never reopen a decision.
    /// This trusted-host API is not mounted on operation or source RPC.
    pub fn stage_connection(&mut self, change: &ConnectionChange) -> Result<ConnectionKey> {
        self.require_connection_host()?;
        let (digest, raw) = change.encoded()?;
        let key = ConnectionKey {
            operation_id: change.operation_id.clone(),
            digest,
        };
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        if request(&tx, &key)?.is_none() {
            persistence::exec(
                &tx,
                "INSERT INTO connection_updates(operation_id,digest,request) VALUES(?1,?2,?3)",
                persistence::params![key.operation_id.clone(), key.digest.clone(), raw],
            )
            .map_err(db)?;
        }
        tx.commit_configuration().map_err(db)?;
        Ok(key)
    }
    /// Atomic CAS of head plus immutable decision. A lost acknowledgment must
    /// inspect this key, not issue a new operation or rebase its expected clock.
    pub fn publish_connection(&mut self, key: &ConnectionKey) -> Result<ConnectionReceipt> {
        self.decide_connection(key, false)
    }
    /// Abandon an unpublished intent; a decided operation keeps its old receipt.
    pub fn abort_connection(&mut self, key: &ConnectionKey) -> Result<ConnectionReceipt> {
        self.decide_connection(key, true)
    }
    fn decide_connection(&mut self, key: &ConnectionKey, abort: bool) -> Result<ConnectionReceipt> {
        self.require_connection_host()?;
        let owner = self.connection.execution_owner();
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        let (change, previous) =
            request(&tx, key)?.ok_or(Error::Conflict("connection intent missing"))?;
        if let Some(receipt) = previous {
            tx.commit_configuration().map_err(db)?;
            return Ok(receipt);
        }
        let current = head(&tx, &change.connection)?;
        let matched = current.as_ref().map(|h| h.revision) == change.expected_revision;
        let outcome = if abort {
            ConnectionOutcome::Aborted
        } else if matched {
            ConnectionOutcome::Committed
        } else {
            ConnectionOutcome::Rejected
        };
        if outcome == ConnectionOutcome::Committed
            && owner
                .connection_leases
                .lock()
                .map_err(|_| Error::Conflict("connection custody poisoned"))?
                .get(&change.connection)
                .copied()
                .unwrap_or(0)
                > 0
        {
            return Err(Error::Conflict(
                "active connection must drain before publication",
            ));
        }
        let revision = if outcome == ConnectionOutcome::Committed {
            Some(current.map_or(0, |h| h.revision + 1))
        } else {
            current.map(|h| h.revision)
        };
        if outcome == ConnectionOutcome::Committed {
            let revision = revision.ok_or(Error::Conflict("connection revision missing"))?;
            if revision > i64::MAX as u64 {
                return Err(Error::Conflict("connection revision exhausted"));
            }
            persistence::exec(&tx,"INSERT INTO connection_heads(id,revision,operation_id,digest,record) VALUES(?1,?2,?3,?4,?5) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,operation_id=excluded.operation_id,digest=excluded.digest,record=excluded.record",
                persistence::params![change.connection.clone(),revision as i64,key.operation_id.clone(),key.digest.clone(),serde_json::to_string(&change)?]).map_err(db)?;
        }
        let receipt = ConnectionReceipt {
            key: key.clone(),
            outcome,
            revision,
        };
        persistence::exec(
            &tx,
            "UPDATE connection_updates SET receipt=?1 WHERE operation_id=?2",
            persistence::params![serde_json::to_string(&receipt)?, key.operation_id.clone()],
        )
        .map_err(db)?;
        tx.commit_configuration().map_err(db)?;
        Ok(receipt)
    }
    /// Read the current committed snapshot, including a retired head's clock.
    pub fn connection_head(&self, connection: &str) -> Result<Option<ConnectionHead>> {
        self.require_connection_host()?;
        identifier(connection)?;
        head(&self.connection, connection)
    }
    /// None means prepared, never successfully applied or safe to replay blindly.
    pub fn connection_receipt(&self, key: &ConnectionKey) -> Result<Option<ConnectionReceipt>> {
        self.require_connection_host()?;
        Ok(request(&self.connection, key)?
            .ok_or(Error::Conflict("connection intent missing"))?
            .1)
    }
    /// Check an opaque operation against its host-selected connection namespace.
    pub fn require_connection_key(&self, connection: &str, key: &ConnectionKey) -> Result<()> {
        self.require_connection_host()?;
        identifier(connection)?;
        let (change, _) =
            request(&self.connection, key)?.ok_or(Error::Conflict("connection intent missing"))?;
        if change.connection != connection {
            return Err(Error::Denied);
        }
        Ok(())
    }
    /// Bind a listener to the current non-retired head. Acquisition shares the
    /// publication transaction owner, closing the read/activation race.
    pub fn lease_connection(&mut self, connection: &str) -> Result<ConnectionLease> {
        self.require_connection_host()?;
        identifier(connection)?;
        let owner = self.connection.execution_owner();
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        let current = head(&tx, connection)?.ok_or(Error::Conflict("connection not published"))?;
        if current.profile.is_none() {
            return Err(Error::Conflict("connection retired"));
        }
        *owner
            .connection_leases
            .lock()
            .map_err(|_| Error::Conflict("connection custody poisoned"))?
            .entry(connection.into())
            .or_default() += 1;
        let lease = ConnectionLease {
            head: current,
            connection: connection.into(),
            owner,
        };
        tx.commit_configuration().map_err(db)?;
        Ok(lease)
    }
}

#[cfg(test)]
#[path = "../tests/unit/connection_config.rs"]
mod tests;
