// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authoritative opaque grant publication and revocation in the deciding store.
use crate::{
    Ledger,
    persistence::{self, driver::Connection},
    store::db,
};
use std::time::{SystemTime, UNIX_EPOCH};
use weaver_contracts::{
    Error, ProviderOAuthDeployment, ProviderOAuthGrant, ProviderOAuthUse, Result, oauth_hex,
};

fn deployment(connection: &Connection) -> Result<Option<ProviderOAuthDeployment>> {
    let value: Option<String> = persistence::maybe(
        connection,
        "SELECT record FROM provider_oauth_deployment WHERE singleton=1",
        (),
        |row| row.get(0),
    )
    .map_err(db)?;
    value
        .map(|record| weaver_contracts::decode(record.as_bytes()))
        .transpose()
}

fn revoked(connection: &Connection, hash: &str) -> Result<bool> {
    persistence::one(
        connection,
        "SELECT EXISTS(SELECT 1 FROM provider_oauth_revocations WHERE token_hash=?1)",
        persistence::params![hash.to_owned()],
        |row| row.get(0),
    )
    .map_err(db)
}

pub(crate) fn now() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|time| time.as_secs())
        .map_err(|_| Error::Conflict("provider OAuth clock unavailable"))
}

pub(crate) fn require(
    connection: &Connection,
    request: Option<&ProviderOAuthUse>,
    scope: &'static str,
) -> Result<Option<u64>> {
    let Some(deployment) = deployment(connection)? else {
        return if request.is_none() {
            Ok(None)
        } else {
            Err(Error::Denied)
        };
    };
    let request = request.ok_or(Error::Denied)?;
    let grant: String = persistence::maybe(
        connection,
        "SELECT record FROM provider_oauth_grants WHERE token_hash=?1 AND NOT EXISTS(SELECT 1 FROM provider_oauth_revocations WHERE token_hash=?1)",
        persistence::params![request.token_hash.clone()], |row| row.get(0),
    ).map_err(db)?.ok_or(Error::Denied)?;
    let grant: ProviderOAuthGrant = weaver_contracts::decode(grant.as_bytes())?;
    weaver_policy::require_provider_oauth(weaver_policy::ProviderOAuthCheck {
        deployment: &deployment,
        grant: &grant,
        request,
        scope,
        now: now()?,
    })?;
    Ok(Some(grant.expires_at))
}

impl Ledger {
    /// Install the deployment binding once. A restart cannot disable or replace it.
    pub fn configure_provider_oauth(
        &mut self,
        config: Option<&ProviderOAuthDeployment>,
    ) -> Result<()> {
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        match (deployment(&tx)?, config) {
            (Some(current), Some(expected)) if &current == expected => {}
            (None, None) => {}
            (None, Some(config)) => {
                config.validate()?;
                persistence::exec(
                    &tx,
                    "INSERT INTO provider_oauth_deployment VALUES(1,?1)",
                    persistence::params![serde_json::to_string(config)?],
                )
                .map_err(db)?;
            }
            _ => return Err(Error::Conflict("provider OAuth deployment changed")),
        }
        tx.commit().map_err(db)
    }

    /// Publish an immutable digest-to-grant binding signed by the pinned issuer.
    pub fn publish_provider_oauth(&mut self, grant: &ProviderOAuthGrant) -> Result<()> {
        let caller = self.source.as_ref().ok_or(Error::Denied)?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, Some(caller))?;
        let config = deployment(&tx)?.ok_or(Error::Denied)?;
        weaver_policy::verify_provider_oauth_grant(&config, grant)?;
        if revoked(&tx, &grant.token_hash)? {
            return Err(Error::Denied);
        }
        let encoded = serde_json::to_string(grant)?;
        let old: Option<String> = persistence::maybe(
            &tx,
            "SELECT record FROM provider_oauth_grants WHERE token_hash=?1",
            persistence::params![grant.token_hash.clone()],
            |row| row.get(0),
        )
        .map_err(db)?;
        match old {
            Some(old) if old == encoded => {}
            Some(_) => return Err(Error::Conflict("provider OAuth digest already bound")),
            None => {
                persistence::exec(
                    &tx,
                    "INSERT INTO provider_oauth_grants VALUES(?1,?2)",
                    persistence::params![grant.token_hash.clone(), encoded],
                )
                .map_err(db)?;
            }
        }
        tx.commit().map_err(db)
    }

    /// Commit an absorbing tombstone even if the matching publication is delayed.
    pub fn revoke_provider_oauth(&mut self, token_hash: &str) -> Result<()> {
        oauth_hex(token_hash, 64)?;
        let caller = self.source.as_ref().ok_or(Error::Denied)?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, Some(caller))?;
        deployment(&tx)?.ok_or(Error::Denied)?;
        persistence::exec(
            &tx,
            "INSERT INTO provider_oauth_revocations VALUES(?1) ON CONFLICT DO NOTHING",
            persistence::params![token_hash.to_owned()],
        )
        .map_err(db)?;
        tx.commit().map_err(db)
    }

    /// Require the same deployment and current token before exposing an operation receipt.
    pub fn inspect_provider_oauth(
        &mut self,
        family: &str,
        node: &str,
        request: Option<&ProviderOAuthUse>,
    ) -> Result<Option<weaver_contracts::ProviderReceipt>> {
        let tx = persistence::begin_family(&mut self.connection, family).map_err(db)?;
        require(&tx, request, "provider:inspect")?;
        let result = super::provider::receipt(&tx, family, node)?;
        tx.commit().map_err(db)?;
        Ok(result)
    }
}
