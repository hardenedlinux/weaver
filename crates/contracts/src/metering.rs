// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Tenant-scoped terminal usage. Raw provider counters are observations.
use crate::{Error, MAX_CREDITS, Result, body_digest, identifier};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Rates are credits per million tokens. Inputs are disjoint usage categories.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MeteringTenant {
    pub issuer: String,
    pub public_key: String,
    pub principals: BTreeSet<String>,
    pub rates: [u64; 4],
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MeteringDeployment {
    pub audience: String,
    pub tenants: BTreeMap<String, MeteringTenant>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub quotas: Option<crate::QuotaDeployment>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub provider_quotes: BTreeMap<String, ProviderQuote>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderQuote {
    pub version: String,
    pub tenant: String,
    pub formula_digest: String,
    pub procurement_rates: [u64; 4],
    pub token_bounds: [u64; 4],
}

fn digest(value: &str, len: usize) -> bool {
    value.len() == len
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl MeteringDeployment {
    pub fn validate(&self) -> Result<()> {
        identifier(&self.audience)?;
        if self.tenants.is_empty() || self.tenants.len() > 1024 {
            return Err(Error::Invalid("metering tenant count"));
        }
        let mut principals = BTreeSet::new();
        let mut keys = BTreeSet::new();
        for (tenant, rule) in &self.tenants {
            identifier(tenant)?;
            identifier(&rule.issuer)?;
            if !digest(&rule.public_key, 64)
                || !keys.insert(&rule.public_key)
                || rule.principals.is_empty()
                || rule.rates.iter().any(|rate| *rate > MAX_CREDITS)
            {
                return Err(Error::Invalid("metering tenant configuration"));
            }
            for principal in &rule.principals {
                identifier(principal)?;
                if !principals.insert(principal) {
                    return Err(Error::Invalid("ambiguous metering principal"));
                }
            }
        }
        if let Some(quotas) = &self.quotas {
            quotas.validate(self)?;
        }
        if !self.provider_quotes.is_empty() && self.quotas.is_none() {
            return Err(Error::Invalid("provider quotes require quota scopes"));
        }
        for (plan, quote) in &self.provider_quotes {
            identifier(&quote.version)?;
            let tenant = self
                .tenants
                .get(&quote.tenant)
                .ok_or(Error::Invalid("quote tenant"))?;
            if !digest(plan, 64)
                || quote.formula_digest != tenant.formula_digest()?
                || quote
                    .procurement_rates
                    .iter()
                    .chain(&quote.token_bounds)
                    .any(|n| *n > MAX_CREDITS)
            {
                return Err(Error::Invalid("provider rate quote"));
            }
        }
        Ok(())
    }

    pub fn authority_digest(&self, tenant: &str) -> Result<String> {
        let rule = self.tenants.get(tenant).ok_or(Error::Denied)?;
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.metering-tenant.v1",
            &self.audience,
            tenant,
            rule,
        ))?))
    }

    pub fn tenant_for(&self, principal: &str) -> Option<&str> {
        self.tenants.iter().find_map(|(tenant, rule)| {
            rule.principals
                .contains(principal)
                .then_some(tenant.as_str())
        })
    }
}

impl MeteringTenant {
    pub fn formula_digest(&self) -> Result<String> {
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.metering.linear-ceil-per-million.v1",
            self.rates,
        ))?))
    }

    pub fn charge(&self, usage: [u64; 4]) -> Result<u64> {
        let sum = self
            .rates
            .iter()
            .zip(usage)
            .try_fold(0u128, |sum, (rate, count)| {
                if count > MAX_CREDITS || *rate > MAX_CREDITS {
                    return Err(Error::Invalid("metering quantity"));
                }
                sum.checked_add(u128::from(*rate) * u128::from(count))
                    .ok_or(Error::Invalid("metering overflow"))
            })?;
        u64::try_from(sum.div_ceil(1_000_000))
            .ok()
            .filter(|charge| *charge <= MAX_CREDITS)
            .ok_or(Error::Invalid("metering charge"))
    }
}

/// Signature covers terminal evidence, normalized counts and the original reservation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MeteringReceipt {
    pub audience: String,
    pub tenant: String,
    pub issuer: String,
    pub application: String,
    pub family: String,
    pub node: String,
    pub origin: String,
    pub plan_digest: String,
    pub target: String,
    pub formula_digest: String,
    pub terminal_digest: String,
    /// Uncached input, cache read, cache write and output tokens, respectively.
    pub tokens: [u64; 4],
    pub signature: String,
}

impl MeteringReceipt {
    pub fn signing_digest(&self) -> Result<String> {
        for id in [
            &self.audience,
            &self.tenant,
            &self.issuer,
            &self.application,
            &self.family,
            &self.node,
            &self.origin,
            &self.target,
        ] {
            identifier(id)?;
        }
        if [
            &self.plan_digest,
            &self.formula_digest,
            &self.terminal_digest,
        ]
        .iter()
        .any(|value| !digest(value, 64))
        {
            return Err(Error::Invalid("metering digest"));
        }
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.provider-terminal-usage.v1",
            &self.audience,
            &self.tenant,
            &self.issuer,
            &self.application,
            &self.family,
            &self.node,
            &self.origin,
            &self.plan_digest,
            &self.target,
            &self.formula_digest,
            &self.terminal_digest,
            self.tokens,
        ))?))
    }

    pub fn validate(&self) -> Result<()> {
        self.signing_digest()?;
        if !digest(&self.signature, 128) {
            return Err(Error::Invalid("metering signature"));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MeteringApplication {
    pub application: String,
    pub charged: u64,
    pub released: u64,
}
