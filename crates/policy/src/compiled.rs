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
        let policy: PolicySet = source
            .parse()
            .map_err(|_| Error::Policy("invalid policy set".into()))?;
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

#[cfg(test)]
#[path = "../tests/unit/cache_storage.rs"]
mod tests;
