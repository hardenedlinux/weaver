// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Authoritative opaque grant publication and revocation in the deciding store.
use crate::{
    Ledger,
    persistence::{self, driver::Connection},
    provider_oauth_witness::{self as witness, Change},
    store::db,
};
use std::time::{SystemTime, UNIX_EPOCH};
use weaver_contracts::{
    Error, ProviderOAuthDeployment, ProviderOAuthGrant, ProviderOAuthUse, Result, oauth_hex,
};

pub(crate) fn deployment(connection: &Connection) -> Result<Option<ProviderOAuthDeployment>> {
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

pub(crate) fn revoked(connection: &Connection, hash: &str) -> Result<bool> {
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

fn active_grant(connection: &Connection, hash: &str) -> Result<ProviderOAuthGrant> {
    let grant: String = persistence::maybe(
        connection,
        "SELECT record FROM provider_oauth_grants WHERE token_hash=?1 AND NOT EXISTS(SELECT 1 FROM provider_oauth_revocations WHERE token_hash=?1)",
        persistence::params![hash.to_owned()], |row| row.get(0),
    ).map_err(db)?.ok_or(Error::Denied)?;
    weaver_contracts::decode(grant.as_bytes())
}

fn require_parent(parent: &ProviderOAuthGrant, grant: &ProviderOAuthGrant) -> Result<()> {
    if parent.parent_token_hash.is_some()
        || parent.issuer != grant.issuer
        || parent.subject != grant.subject
        || parent.client != grant.client
        || parent.audience != grant.audience
        || parent.certificate_sha256 == grant.certificate_sha256
        || grant.not_before < parent.not_before
        || grant.expires_at > parent.expires_at
        || !grant
            .scopes
            .iter()
            .all(|scope| parent.scopes.contains(scope))
    {
        return Err(Error::Denied);
    }
    Ok(())
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
    witness::require_current(connection, &deployment)?;
    let request = request.ok_or(Error::Denied)?;
    let grant = active_grant(connection, &request.token_hash)?;
    let relaying =
        deployment.relay_certificate_sha256.as_ref() == Some(&request.certificate_sha256);
    match (
        &grant.parent_token_hash,
        &request.ingress_certificate_sha256,
        relaying,
    ) {
        (None, None, false) => {}
        (Some(parent_hash), Some(ingress), true) => {
            let parent = active_grant(connection, parent_hash)?;
            require_parent(&parent, &grant)?;
            if &parent.certificate_sha256 != ingress {
                return Err(Error::Denied);
            }
        }
        _ => return Err(Error::Denied),
    }
    weaver_policy::require_provider_oauth(weaver_policy::ProviderOAuthCheck {
        deployment: &deployment,
        grant: &grant,
        request,
        scope,
        now: now()?,
    })?;
    Ok(Some(grant.expires_at))
}

fn can_enable_witness(current: &ProviderOAuthDeployment, next: &ProviderOAuthDeployment) -> bool {
    current.witness_file.is_none()
        && current.relay_certificate_sha256.is_none()
        && next.witness_file.is_some()
        && current.issuer == next.issuer
        && current.subject == next.subject
        && current.client == next.client
        && current.audience == next.audience
        && current.public_key == next.public_key
}

fn verify_publication(
    tx: &Connection,
    mut config: ProviderOAuthDeployment,
    grant: &ProviderOAuthGrant,
) -> Result<()> {
    let (epoch, key) = witness::issuer_key(tx, &config)?;
    if epoch != grant.issuer_epoch {
        return Err(Error::Denied);
    }
    config.public_key = key;
    weaver_policy::verify_provider_oauth_grant(&config, grant)?;
    match &grant.parent_token_hash {
        Some(parent) => {
            if config.relay_certificate_sha256.as_ref() != Some(&grant.certificate_sha256) {
                return Err(Error::Denied);
            }
            require_parent(&active_grant(tx, parent)?, grant)?;
        }
        None if config.relay_certificate_sha256.as_ref() == Some(&grant.certificate_sha256) => {
            return Err(Error::Denied);
        }
        None => {}
    }
    if revoked(tx, &grant.token_hash)? {
        return Err(Error::Denied);
    }
    Ok(())
}

impl Ledger {
    /// Install the binding or enable its witness once without replacing issuer identity.
    pub fn configure_provider_oauth(
        &mut self,
        config: Option<&ProviderOAuthDeployment>,
    ) -> Result<()> {
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        match (deployment(&tx)?, config) {
            (Some(current), Some(expected)) if &current == expected => {}
            (None, None) => {}
            (Some(current), Some(config)) if can_enable_witness(&current, config) => {
                config.validate()?;
                persistence::exec(
                    &tx,
                    "UPDATE provider_oauth_deployment SET record=?1 WHERE singleton=1",
                    persistence::params![serde_json::to_string(config)?],
                )
                .map_err(db)?;
            }
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
        if let Some(config) = config {
            witness::apply(&tx, config, None)?;
        }
        tx.commit().map_err(db)
    }

    /// Publish an immutable digest-to-grant binding signed by the pinned issuer.
    pub fn publish_provider_oauth(&mut self, grant: &ProviderOAuthGrant) -> Result<()> {
        let caller = self.source.as_ref().ok_or(Error::Denied)?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, Some(caller))?;
        let config = deployment(&tx)?.ok_or(Error::Denied)?;
        witness::require_current(&tx, &config)?;
        verify_publication(&tx, config, grant)?;
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
        let config = deployment(&tx)?.ok_or(Error::Denied)?;
        witness::apply(&tx, &config, Some(Change::Revoke(token_hash.to_owned())))?;
        tx.commit_provider().map_err(db)
    }

    /// Install one current-issuer-signed successor key through source authority.
    pub fn rotate_provider_oauth_issuer(
        &mut self,
        rotation: &weaver_contracts::ProviderOAuthIssuerRotation,
    ) -> Result<()> {
        let caller = self.source.as_ref().ok_or(Error::Denied)?;
        let tx = persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, Some(caller))?;
        let config = deployment(&tx)?.ok_or(Error::Denied)?;
        witness::apply(&tx, &config, Some(Change::Rotate(rotation.clone())))?;
        tx.commit_provider().map_err(db)
    }

    /// Require the same deployment and current token before exposing an operation receipt.
    pub fn inspect_provider_oauth(
        &mut self,
        family: &str,
        node: &str,
        request: Option<&ProviderOAuthUse>,
    ) -> Result<Option<weaver_contracts::ProviderReceipt>> {
        let tx = persistence::begin_family(&mut self.connection, family).map_err(db)?;
        tx.check_provider_oauth(request, "provider:inspect")?;
        let result = super::provider::receipt(&tx, family, node)?;
        tx.commit().map_err(db)?;
        Ok(result)
    }
}
