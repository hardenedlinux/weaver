// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Versioned provider plans and the tenant tariffs required to admit them.

use crate::{
    Error, MAX_CREDITS, MeteringDeployment, ProviderQuote, Result, body_digest, identifier,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// An ordered provider plan snapshot linked to its parent catalog.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderCatalog {
    pub parent: String,
    pub entries: BTreeMap<String, CatalogEntry>,
}

/// One plan's module, capability, latency and pricing declarations.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CatalogEntry {
    pub module: String,
    pub capabilities: Vec<String>,
    pub latency_millis: u64,
    pub user_rates: [u64; 4],
    pub quote: ProviderQuote,
}

impl ProviderCatalog {
    pub fn record(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }
    pub fn digest(&self) -> Result<String> {
        Ok(body_digest(&serde_json::to_string(&(
            "weaver.provider-catalog.v1",
            self,
        ))?))
    }

    pub fn validate(&self, deployment: &MeteringDeployment) -> Result<()> {
        if deployment.quotas.is_none() || self.entries.len() > 256 {
            return Err(Error::Invalid("provider catalog bounds or quota scopes"));
        }
        let mut tariffs = BTreeMap::new();
        for (plan, entry) in &self.entries {
            entry.validate_shape()?;
            let tenant = deployment
                .tenants
                .get(&entry.quote.tenant)
                .ok_or(Error::Denied)?;
            if tariffs
                .insert(&entry.quote.tenant, entry.user_rates)
                .is_some_and(|prior| prior != entry.user_rates)
            {
                return Err(Error::Invalid("mixed tenant formulas in catalog"));
            }
            let mut tenant = tenant.clone();
            tenant.rates = entry.user_rates;
            entry.quote.validate(plan, &tenant)?;
            tenant.charge(entry.quote.token_bounds)?;
        }
        Ok(())
    }
}

impl CatalogEntry {
    fn validate_shape(&self) -> Result<()> {
        identifier(&self.module)?;
        if self.capabilities.len() > 32
            || self.latency_millis == 0
            || self.latency_millis > MAX_CREDITS
        {
            return Err(Error::Invalid("provider catalog entry bounds"));
        }
        self.capabilities
            .iter()
            .try_for_each(|capability| identifier(capability))
    }
}
