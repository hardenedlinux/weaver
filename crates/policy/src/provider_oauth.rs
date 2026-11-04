// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Project authenticated issuer grants into the SPEC resource-use contract.
use cedar_poo_runtime::gateway::oauth::{
    Confirmation, CurrentUse, Grant, Identity, ReplayGuard, SenderObservation, Target,
};
use weaver_contracts::{
    Error, ProviderOAuthDeployment, ProviderOAuthGrant, ProviderOAuthUse, Result,
};

/// Verify the issuer evidence before the source owner can publish it.
pub fn verify_provider_oauth_grant(
    deployment: &ProviderOAuthDeployment,
    grant: &ProviderOAuthGrant,
) -> Result<()> {
    grant.validate()?;
    if grant.issuer != deployment.issuer
        || grant.subject != deployment.subject
        || grant.client != deployment.client
        || grant.audience != deployment.audience
    {
        return Err(Error::Denied);
    }
    crate::delta_review::verify_signature(
        &deployment.public_key,
        &grant.signing_digest()?,
        &grant.signature,
    )
}

/// Deciding-store facts for one mTLS resource check.
pub struct ProviderOAuthCheck<'a> {
    pub deployment: &'a ProviderOAuthDeployment,
    pub grant: &'a ProviderOAuthGrant,
    pub request: &'a ProviderOAuthUse,
    pub scope: &'static str,
    pub now: u64,
}

/// Evaluate the upstream mTLS resource requirement over deciding-store facts.
pub fn require_provider_oauth(check: ProviderOAuthCheck<'_>) -> Result<()> {
    let ProviderOAuthCheck {
        deployment,
        grant,
        request,
        scope,
        now,
    } = check;
    if grant.token_hash != request.token_hash {
        return Err(Error::Denied);
    }
    let current = CurrentUse {
        grant: Grant {
            identity: Identity {
                issuer: grant.issuer.clone(),
                subject: grant.subject.clone(),
                client: grant.client.clone(),
            },
            audiences: vec![grant.audience.clone()],
            scopes: grant.scopes.clone(),
            token_hash: grant.token_hash.clone(),
            not_before: grant.not_before,
            expires_at: grant.expires_at,
            confirmation: Confirmation::Mtls(grant.certificate_sha256.clone()),
        },
        target: Target {
            identity: Identity {
                issuer: deployment.issuer.clone(),
                subject: deployment.subject.clone(),
                client: deployment.client.clone(),
            },
            audience: deployment.audience.clone(),
            required_scopes: vec![scope.into()],
            // The mTLS arm binds the TLS sender. The RPC method independently
            // selects scope, and the original plan binds the actual effect.
            method: String::new(),
            uri: String::new(),
        },
        sender: SenderObservation::Mtls(request.certificate_sha256.clone()),
        now,
        max_proof_age: 0,
        token_authenticated: true,
        active: true,
    };
    // mTLS has no DPoP proof reservation. Existing Cedar and affine effect
    // checks remain mandatory in the enclosing deciding transaction.
    if !ReplayGuard::default()
        .admit(true, &current)
        .map_err(Error::Policy)?
    {
        return Err(Error::Denied);
    }
    Ok(())
}
