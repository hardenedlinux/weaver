// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Exact retained-member bijection and budget conservation in one `Turso` scope.
use crate::{
    persistence::{self, WriteScope},
    store::{db, integer},
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use weaver_contracts::{Error, Result};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Member {
    pub digest: String,
    pub ceiling: u64,
}
#[derive(Default, Serialize)]
#[serde(transparent)]
pub(crate) struct Members(BTreeMap<String, Member>);

impl Members {
    pub(crate) fn new() -> Self {
        Self::default()
    }
}
impl std::ops::Deref for Members {
    type Target = BTreeMap<String, Member>;
    fn deref(&self) -> &Self::Target {
        &self.0
    }
}
impl std::ops::DerefMut for Members {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}
impl IntoIterator for Members {
    type Item = (String, Member);
    type IntoIter = std::collections::btree_map::IntoIter<String, Member>;
    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}
impl<'de> Deserialize<'de> for Members {
    fn deserialize<D: serde::Deserializer<'de>>(decoder: D) -> std::result::Result<Self, D::Error> {
        struct Unique;
        impl<'de> serde::de::Visitor<'de> for Unique {
            type Value = Members;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("unique original reservation members")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> std::result::Result<Members, M::Error> {
                let mut members = Members::new();
                while let Some((key, value)) = map.next_entry::<String, Member>()? {
                    if members.insert(key, value).is_some() {
                        return Err(serde::de::Error::custom(
                            "duplicate original reservation member",
                        ));
                    }
                }
                Ok(members)
            }
        }
        decoder.deserialize_map(Unique)
    }
}
pub(crate) type Family = BTreeMap<(String, String, String), Member>;

const COMMITTED: &str = "SELECT node,kind,reservations FROM execution_claims WHERE family=?1";
const PROJECTED: &str =
    "SELECT node,'' AS member,digest,reserved,'request' AS kind,json_extract(proposal,'$.ceiling') AS original FROM operations WHERE family=?1
     UNION ALL SELECT node,message,digest,reserved,'stream',json_extract(proposal,'$.ceiling') FROM stream_messages WHERE family=?1
     UNION ALL SELECT node,'',digest,reserved,'provider',json_extract(plan,'$.ceiling') FROM provider_runs WHERE family=?1";

#[cfg(feature = "commit-observer")]
thread_local! {
    static PREPARE_MANIFEST_PROGRAMS: std::cell::Cell<bool> = const { std::cell::Cell::new(true) };
}

/// Select fixed manifest program preflight in the observed worker.
#[cfg(feature = "commit-observer")]
pub fn use_prepared_manifest_programs(prepared: bool) {
    PREPARE_MANIFEST_PROGRAMS.set(prepared);
}

pub(crate) fn warm_programs(connection: &persistence::driver::Connection) {
    if prepared_programs() {
        for sql in [COMMITTED, PROJECTED] {
            let _ = futures_executor::block_on(connection.prepare_cached(sql));
        }
    }
}

fn prepared_programs() -> bool {
    #[cfg(feature = "commit-observer")]
    {
        PREPARE_MANIFEST_PROGRAMS.get()
    }
    #[cfg(not(feature = "commit-observer"))]
    {
        true
    }
}

fn read_members<T>(
    tx: &WriteScope<'_>,
    sql: &'static str,
    family: &str,
    decode: impl FnMut(&persistence::Row) -> persistence::driver::Result<T>,
) -> Result<Vec<T>> {
    tx.provider_manifest_reads(|| {
        let rows = persistence::read_all_manifest(
            tx,
            sql,
            family,
            prepared_programs(),
            sql == PROJECTED,
            decode,
        );
        rows.map_err(db)
    })
}

fn conflict() -> Error {
    Error::Conflict("original claims or shared execution exposure not retained")
}

fn committed(tx: &WriteScope<'_>, family: &str) -> Result<Family> {
    let rows = read_members(tx, COMMITTED, family, |r| {
        Ok((
            r.get::<String>(0)?,
            r.get::<String>(1)?,
            r.get::<String>(2)?,
        ))
    })?;
    let mut result = Family::new();
    for (node, kind, body) in rows {
        if !matches!(kind.as_str(), "request" | "stream" | "provider") {
            return Err(conflict());
        }
        let members: Members = serde_json::from_str(&body)?;
        if members.is_empty() {
            return Err(conflict());
        }
        for (id, member) in members {
            if result
                .insert((node.clone(), kind.clone(), id), member)
                .is_some()
            {
                return Err(conflict());
            }
        }
    }
    Ok(result)
}

fn projected(tx: &WriteScope<'_>, family: &str) -> Result<(Family, u64)> {
    let rows = read_members(tx, PROJECTED, family, |r| {
        Ok((
            r.get::<String>(0)?,
            r.get::<String>(1)?,
            r.get::<String>(2)?,
            integer(r, 3)?,
            r.get::<String>(4)?,
            integer(r, 5)?,
        ))
    })?;
    let mut result = Family::new();
    let mut total = 0u64;
    for (node, id, digest, ceiling, kind, original) in rows {
        if ceiling != original {
            return Err(conflict());
        }
        total = total.checked_add(ceiling).ok_or_else(conflict)?;
        if result
            .insert((node, kind, id), Member { digest, ceiling })
            .is_some()
        {
            return Err(conflict());
        }
    }
    Ok((result, total))
}

pub(crate) fn verified_members(
    tx: &WriteScope<'_>,
    family: &str,
    exposure: &crate::task_origins::Exposure,
) -> Result<Family> {
    let original_members = committed(tx, family)?;
    let (rows, total) = projected(tx, family)?;
    let total = total
        .checked_sub(crate::metering::applied_release(tx, family)?)
        .ok_or_else(conflict)?;
    if exposure.budget != exposure.original_budget
        || exposure.held > exposure.budget
        || exposure.held != total
        || original_members != rows
    {
        return Err(conflict());
    }
    Ok(original_members)
}
