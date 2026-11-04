// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

use crate::{
    Error, MAX_CREDITS, MeteringDeployment, ProviderQuote, Result, body_digest, identifier,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderCatalog {
    pub parent: String,
    pub entries: BTreeMap<String, CatalogEntry>,
}

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
        for (plan, entry) in &self.entries {
            identifier(&entry.module)?;
            if entry.capabilities.len() > 32
                || entry.latency_millis == 0
                || entry.latency_millis > MAX_CREDITS
            {
                return Err(Error::Invalid("provider catalog entry bounds"));
            }
            for capability in &entry.capabilities {
                identifier(capability)?;
            }
            let tenant = deployment
                .tenants
                .get(&entry.quote.tenant)
                .ok_or(Error::Denied)?;
            if tenant.rates != entry.user_rates {
                return Err(Error::Denied);
            }
            entry.quote.validate(plan, tenant)?;
            tenant.charge(entry.quote.token_bounds)?;
        }
        Ok(())
    }
}
