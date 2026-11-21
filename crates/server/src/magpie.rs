// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Stock Magpie uses the standard HTTP Provider. This optional host API owns
//! only Weaver's connection state: no Go embedding, fork or upstream file edits.
use crate::{HttpProfile, ServiceRuntime, admission::Admission};
use std::path::PathBuf;
use weaver_contracts::{Error, Result};
pub use weaver_ledger::{
    ConnectionChange, ConnectionHead, ConnectionKey, ConnectionOutcome, ConnectionProfile,
    ConnectionReceipt,
};

/// Validated operation identity using the ledger's existing identifier grammar.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ConnectionOperationId(String);
impl TryFrom<&str> for ConnectionOperationId {
    type Error = Error;
    fn try_from(value: &str) -> Result<Self> {
        weaver_contracts::identifier(value)?;
        Ok(Self(value.into()))
    }
}

/// Bounded trusted control plane on the caller's existing tracked runtime.
/// Never mount these methods on Magpie's operation credential endpoint.
#[derive(Clone)]
pub struct ConnectionControl {
    database: PathBuf,
    connection: String,
    runtime: ServiceRuntime,
    admission: Admission,
}
impl ConnectionControl {
    /// Select a trusted database and principal on an existing tracked runtime.
    pub fn new(database: PathBuf, principal: &str, runtime: ServiceRuntime) -> Result<Self> {
        Ok(Self {
            database,
            connection: HttpProfile::connection_id(principal)?,
            runtime,
            admission: Admission::new(1),
        })
    }
    async fn run<T: Send + 'static>(
        &self,
        action: impl FnOnce(&mut weaver_ledger::Ledger) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let slot = self
            .admission
            .publication()
            .map_err(|_| Error::Conflict("connection control capacity"))?;
        let database = self.database.clone();
        self.runtime
            .spawn_blocking(slot, move |_| {
                let mut ledger = weaver_ledger::Ledger::open(database)?;
                action(&mut ledger)
            })?
            .await
            .map_err(|_| Error::Conflict("connection control interrupted"))?
    }
    /// Persist intent before publication. Exact retries keep its original bytes.
    /// `operation_id` uses the existing `ConnectionChange` identifier contract;
    /// the ledger validates it before persistence, rather than adding a new ID grammar.
    pub async fn prepare(
        &self,
        operation_id: ConnectionOperationId,
        expected_revision: Option<u64>,
        profile: Option<HttpProfile>,
    ) -> Result<ConnectionKey> {
        let change = ConnectionChange {
            operation_id: operation_id.0,
            connection: self.connection.clone(),
            expected_revision,
            profile: profile.map(|p| ConnectionProfile {
                session: p.session,
                token_sha256: p.token_sha256,
            }),
        };
        self.run(move |ledger| ledger.stage_connection(&change))
            .await
    }
    /// CAS current state and decision together. A live listener must drain first.
    pub async fn publish(&self, key: ConnectionKey) -> Result<ConnectionReceipt> {
        let id = self.connection.clone();
        self.run(move |ledger| {
            ledger.require_connection_key(&id, &key)?;
            ledger.publish_connection(&key)
        })
        .await
    }
    /// Abort only an unpublished intent; never rewrite a decided receipt.
    pub async fn abort(&self, key: ConnectionKey) -> Result<ConnectionReceipt> {
        let id = self.connection.clone();
        self.run(move |ledger| {
            ledger.require_connection_key(&id, &key)?;
            ledger.abort_connection(&key)
        })
        .await
    }
    /// Inspect the original operation; absence is unresolved preparation.
    pub async fn receipt(&self, key: ConnectionKey) -> Result<Option<ConnectionReceipt>> {
        let id = self.connection.clone();
        self.run(move |ledger| {
            ledger.require_connection_key(&id, &key)?;
            ledger.connection_receipt(&key)
        })
        .await
    }
    /// Only this current snapshot may activate a listener; receipts are history.
    pub async fn current(&self) -> Result<Option<ConnectionHead>> {
        let id = self.connection.clone();
        self.run(move |ledger| ledger.connection_head(&id)).await
    }
}

/// Startup publication joins the existing tracked runtime and deciding store.
/// There is no per-request storage read or implicit overwrite of a changed head.
pub(crate) async fn bind(
    profile: &HttpProfile,
    gateway: &crate::grpc::Gateway,
) -> Result<weaver_ledger::ConnectionLease> {
    let id = HttpProfile::connection_id(&gateway.config.principal)?;
    let desired = weaver_ledger::ConnectionProfile {
        session: profile.session.clone(),
        token_sha256: profile.token_sha256,
    };
    let database = gateway.config.database.clone();
    let slot = gateway
        .admission
        .publication()
        .map_err(|_| Error::Conflict("connection startup capacity"))?;
    gateway
        .runtime
        .spawn_blocking(slot, move |_| {
            let mut ledger = weaver_ledger::Ledger::open(database)?;
            if ledger.connection_head(&id)?.is_none() {
                let change = weaver_ledger::ConnectionChange {
                    operation_id: format!(
                        "initial-{}",
                        weaver_contracts::body_digest(&serde_json::to_string(&(&id, &desired))?)
                    ),
                    connection: id.clone(),
                    expected_revision: None,
                    profile: Some(desired.clone()),
                };
                let key = ledger.stage_connection(&change)?;
                ledger.publish_connection(&key)?;
            }
            let lease = ledger.lease_connection(&id)?;
            if lease.head().profile.as_ref() != Some(&desired) {
                return Err(Error::Conflict(
                    "HTTP profile differs from committed connection",
                ));
            }
            Ok(lease)
        })?
        .await
        .map_err(|_| Error::Conflict("connection startup interrupted"))?
}

#[cfg(test)]
#[path = "../tests/unit/magpie_connection.rs"]
mod tests;
