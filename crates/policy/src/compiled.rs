// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Bounded per-thread cache of exact immutable Policy source; decisions are never cached.
use cedar_policy::PolicySet;
use std::cell::RefCell;
use weaver_contracts::{Error, Result};

thread_local! {static COMPILED:RefCell<Vec<(String,PolicySet)>>=const {RefCell::new(Vec::new())};}
pub(crate) fn with_policy<T>(source: &str, run: impl FnOnce(&PolicySet) -> T) -> Result<T> {
    if source.len() > 65_536 {
        return Err(Error::Invalid("Policy source bound"));
    }
    COMPILED.with(|cache| {
        let mut cache = cache.borrow_mut();
        if let Some((_, policy)) = cache.iter().find(|(text, _)| text == source) {
            return Ok(run(policy));
        }
        let policy = parse(source)?;
        if cache.len() == 8 {
            cache.remove(0);
        }
        cache.push((source.to_owned(), policy));
        let (_, policy) = cache
            .last()
            .ok_or(Error::Policy("compiled cache missing".into()))?;
        Ok(run(policy))
    })
}

/// Cedar text or the official materialized PolicySet JSON, preserving named IDs.
/// JSON is decoded with duplicate rejection before the upstream native loader.
pub(crate) fn parse(source: &str) -> Result<PolicySet> {
    if source.trim_start().starts_with('{') {
        let value: serde_json::Value = weaver_contracts::decode(source.as_bytes())?;
        let artifact = serde_json::to_string(&value)?
            .parse()
            .map_err(|_| Error::Policy("invalid compiled Cedar artifact".into()))?;
        cedar_poo_runtime::load_policy_set(&artifact).map_err(Error::Policy)
    } else {
        source
            .parse()
            .map_err(|_| Error::Policy("invalid policy set".into()))
    }
}

#[cfg(test)]
#[path = "../tests/unit/cache_storage.rs"]
mod tests;
