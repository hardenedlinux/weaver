// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Persisted bounded bearer material and shared expiry/scope checks.

use serde::{Deserialize, Serialize};
use zeroize::Zeroize;

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StoredToken {
    pub access: String,
    pub refresh: Option<String>,
    pub issued_at: u64,
    pub expires_at: u64,
    pub scopes: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh_at: Option<u64>,
}

impl Drop for StoredToken {
    fn drop(&mut self) {
        self.access.zeroize();
        self.refresh.zeroize();
    }
}

impl StoredToken {
    pub fn fresh(&self, now: u64) -> bool {
        now >= self.issued_at
            && now.saturating_add(30) < self.expires_at
            && self.refresh_at.is_none_or(|at| now < at)
    }

    pub fn valid(&self, required: &[String]) -> bool {
        valid_access(&self.access)
            && self.expires_at > self.issued_at
            && self.refresh_at.is_none_or(|at| at > self.issued_at)
            && scope_matches(required, &self.scopes)
            && self
                .refresh
                .as_ref()
                .is_none_or(|r| !r.trim().is_empty() && r.len() <= 16 * 1024)
    }
}

pub(super) fn scope_matches(required: &[String], granted: &[String]) -> bool {
    required.iter().all(|s| granted.contains(s)) && granted.iter().all(|s| required.contains(s))
}

pub(super) fn valid_access(access: &str) -> bool {
    !access.is_empty()
        && access.len() <= 16 * 1024
        && access.trim() == access
        && reqwest::header::HeaderValue::from_str(access).is_ok()
}

#[cfg(test)]
#[path = "../../tests/unit/oauth.rs"]
mod tests;
