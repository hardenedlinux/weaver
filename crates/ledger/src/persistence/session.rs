// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One verified durable `Turso` session owned by the Gateway host.
use super::{driver, one, script};
use std::{
    ops::Deref,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};

/// One FULL/WAL Turso connection. There is no automatic engine/store conversion.
pub struct Session {
    pub(super) connection: driver::Connection,
    pub(super) owner: Arc<super::owner::Owner>,
    pub(super) poisoned: AtomicBool,
    pub(super) timings: super::TransactionTimings,
    pub(crate) range_cancelled: Option<Arc<dyn Fn() -> bool + Send + Sync>>,
    #[cfg(feature = "commit-observer")]
    pub(super) scope_trace: Option<Vec<super::ProviderScopeSample>>,
    #[cfg(any(test, feature = "commit-observer"))]
    pub(super) commit_observer: Option<Arc<dyn super::commit_observer::Observer>>,
}
impl Session {
    /// Open through MRR Data and read back the required durability settings.
    pub fn open(path: impl AsRef<Path>) -> driver::Result<Self> {
        Self::connect(path.as_ref(), None)
    }
    /// Select MVCC explicitly; default opens join this live owner's profile.
    pub fn open_with_journal(
        path: impl AsRef<Path>,
        journal: super::Journal,
    ) -> driver::Result<Self> {
        Self::connect(path.as_ref(), Some(journal))
    }
    fn connect(path: &Path, requested: Option<super::Journal>) -> driver::Result<Self> {
        let owner = super::owner::open(path, requested)?;
        let connection = owner.database.connect()?;
        connection.busy_timeout(Duration::from_secs(10))?;
        script(
            &connection,
            "PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
        )?;
        let mode: String = one(&connection, "PRAGMA journal_mode", (), |r| r.get(0))?;
        let synchronous: i64 = one(&connection, "PRAGMA synchronous", (), |r| r.get(0))?;
        let foreign_keys: i64 = one(&connection, "PRAGMA foreign_keys", (), |r| r.get(0))?;
        let expected = match owner.journal {
            super::Journal::Wal => "wal",
            super::Journal::Mvcc => "mvcc",
        };
        if mode != expected || synchronous != 2 || foreign_keys != 1 {
            return Err(driver::Error::Misuse(
                "required WAL/FULL/foreign-key storage profile unavailable".into(),
            ));
        }
        Ok(Self {
            connection,
            owner,
            poisoned: AtomicBool::new(false),
            timings: super::TransactionTimings::default(),
            range_cancelled: None,
            #[cfg(feature = "commit-observer")]
            scope_trace: None,
            #[cfg(any(test, feature = "commit-observer"))]
            commit_observer: None,
        })
    }
    /// Read-only session statistics; not a currentness or completion observation.
    pub fn timings(&self) -> super::TransactionTimings {
        self.timings
    }
    #[cfg(feature = "commit-observer")]
    pub(crate) fn trace_provider_scopes(&mut self) {
        self.scope_trace = Some(Vec::with_capacity(super::scope_trace::CAPACITY));
    }

    #[cfg(feature = "commit-observer")]
    pub(crate) fn provider_scope_samples(&self) -> &[super::ProviderScopeSample] {
        self.scope_trace.as_deref().unwrap_or_default()
    }
    pub(crate) fn prepare_provider_domain(&mut self) {
        super::timing::measure(&mut self.timings.provider_domain_prepare, || {
            crate::domains::warm_provider_domain_plan(&self.connection);
        });
    }
    pub(crate) fn prepare_provider_original(
        &mut self,
        family: &str,
    ) -> Option<crate::task_origins::PreparedOriginal> {
        self.require_quiescent().ok()?;
        super::timing::measure(&mut self.timings.provider_original_prepare, || {
            crate::task_origins::prepare(&self.connection, family)
        })
    }
    pub(crate) fn prepare_provider_publication(
        &mut self,
        family: &str,
    ) -> weaver_contracts::Result<crate::provider_publication::Prepared> {
        self.require_quiescent().map_err(crate::store::db)?;
        super::timing::measure(&mut self.timings.provider_publication_prepare, || {
            crate::provider_publication::prepare(&self.connection, family)
        })
    }
    pub(crate) fn prepare_provider_oauth(
        &mut self,
        request: Option<&weaver_contracts::ProviderOAuthUse>,
        scope: &'static str,
    ) -> weaver_contracts::Result<Option<crate::provider_oauth::PreparedUse>> {
        self.require_quiescent().map_err(crate::store::db)?;
        super::timing::measure(&mut self.timings.provider_oauth_prepare, || {
            crate::provider_oauth::prepare(&self.connection, request, scope)
        })
    }
    /// Initialize this live MVCC owner's ledger once; this never caches authorization.
    pub(crate) fn initialize_ledger(&mut self) -> driver::Result<()> {
        self.require_quiescent()?;
        let owner = self.owner.clone();
        let mvcc = owner.journal == super::Journal::Mvcc;
        if mvcc && owner.ledger_initialized.load(Ordering::Acquire) {
            return Ok(());
        }
        let transaction = super::begin(self)?;
        if !mvcc || !owner.ledger_initialized.load(Ordering::Acquire) {
            script(&transaction, crate::schema::SCHEMA)?;
        }
        transaction.commit()?;
        owner.ledger_initialized.store(true, Ordering::Release);
        Ok(())
    }
    /// Refuse reuse after an unresolved or failed transaction.
    pub fn require_quiescent(&self) -> driver::Result<()> {
        if self.poisoned.load(Ordering::Acquire) || !self.connection.is_autocommit()? {
            return Err(driver::Error::Misuse(
                "unresolved storage transaction".into(),
            ));
        }
        Ok(())
    }
    /// Report clean completion only when no transaction remains unresolved.
    pub fn close(self) -> driver::Result<()> {
        self.require_quiescent()
    }
}
impl Deref for Session {
    type Target = driver::Connection;
    fn deref(&self) -> &Self::Target {
        &self.connection
    }
}
