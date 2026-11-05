// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Exact namespaces for origin, shared budget/history, API key, user and tenant.
use weaver_contracts::MeteringDeployment;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Roots {
    execution: [String; 3],
    quota: Option<[String; 3]>,
}
impl From<[String; 3]> for Roots {
    fn from(execution: [String; 3]) -> Self {
        Self {
            execution,
            quota: None,
        }
    }
}
impl Roots {
    pub(super) fn new(
        execution: [String; 3],
        config: Option<&MeteringDeployment>,
        family: &str,
    ) -> Self {
        Self {
            execution,
            quota: config.and_then(|config| quota_keys(config, family)),
        }
    }
    pub(super) fn key(&self, index: usize) -> Option<&str> {
        if index < 3 {
            Some(&self.execution[index])
        } else {
            self.quota.as_ref().map(|keys| keys[index - 3].as_str())
        }
    }
    pub(super) fn overlaps(&self, other: &Self) -> bool {
        (0..6).any(|i| self.key(i).is_some_and(|key| other.key(i) == Some(key)))
    }
}
fn quota_keys(config: &MeteringDeployment, family: &str) -> Option<[String; 3]> {
    let quotas = config.quotas.as_ref()?;
    let key = quotas.families.get(family)?;
    let principal = &quotas.keys.get(key)?.principal;
    let tenant = config.tenant_for(principal)?;
    Some([key.clone(), principal.clone(), tenant.to_owned()])
}

#[cfg(test)]
#[path = "../../tests/unit/scope_keys.rs"]
mod tests;
