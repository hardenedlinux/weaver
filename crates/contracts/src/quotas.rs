// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Deployment quota bindings across credential keys, principals and tenants.

use crate::{Error, MAX_CREDITS, MeteringDeployment, Result, identifier};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Keys here are stable deployment credential identifiers, never bearer secrets.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaDeployment {
    pub families: BTreeMap<String, String>,
    pub keys: BTreeMap<String, QuotaKey>,
    pub users: BTreeMap<String, u64>,
    pub tenants: BTreeMap<String, u64>,
}

/// The principal binding and credit limit for a stable credential identifier.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct QuotaKey {
    pub principal: String,
    pub limit: u64,
}

impl QuotaDeployment {
    pub(crate) fn validate(&self, metering: &MeteringDeployment) -> Result<()> {
        fn limit(value: u64) -> Result<()> {
            if !(1..=MAX_CREDITS).contains(&value) {
                return Err(Error::Invalid("quota limit"));
            }
            Ok(())
        }
        if self.keys.is_empty() || self.families.is_empty() {
            return Err(Error::Invalid("quota bindings required"));
        }
        for (name, key) in &self.keys {
            identifier(name)?;
            limit(key.limit)?;
            let tenant = metering.tenant_for(&key.principal).ok_or(Error::Denied)?;
            limit(*self.users.get(&key.principal).ok_or(Error::Denied)?)?;
            limit(*self.tenants.get(tenant).ok_or(Error::Denied)?)?;
        }
        for (family, key) in &self.families {
            identifier(family)?;
            if !self.keys.contains_key(key) {
                return Err(Error::Invalid("quota family binding"));
            }
        }
        Ok(())
    }
}
