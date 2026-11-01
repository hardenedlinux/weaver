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
type Family = BTreeMap<(String, String, String), Member>;

fn conflict() -> Error {
    Error::Conflict("original claims or shared execution exposure not retained")
}

fn committed(tx: &WriteScope<'_>, family: &str) -> Result<Family> {
    let rows = persistence::read_all(
        tx,
        "SELECT node,kind,reservations FROM execution_claims WHERE family=?1",
        [family],
        |r| {
            Ok((
                r.get::<String>(0)?,
                r.get::<String>(1)?,
                r.get::<String>(2)?,
            ))
        },
    )
    .map_err(db)?;
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
    let rows=persistence::read_all(tx,
        "SELECT node,'' AS member,digest,reserved,'request' AS kind,json_extract(proposal,'$.ceiling') AS original FROM operations WHERE family=?1
         UNION ALL SELECT node,message,digest,reserved,'stream',json_extract(proposal,'$.ceiling') FROM stream_messages WHERE family=?1
         UNION ALL SELECT node,'',digest,reserved,'provider',json_extract(plan,'$.ceiling') FROM provider_runs WHERE family=?1",
        [family],|r|Ok((r.get::<String>(0)?,r.get::<String>(1)?,r.get::<String>(2)?,integer(r,3)?,r.get::<String>(4)?,integer(r,5)?))).map_err(db)?;
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

pub(crate) fn require(tx: &WriteScope<'_>, family: &str) -> Result<()> {
    let (held, budget, original) = persistence::one(
        tx,
        "SELECT held,budget,json_extract(record,'$.budget') FROM tasks WHERE family=?1",
        [family],
        |r| Ok((integer(r, 0)?, integer(r, 1)?, integer(r, 2)?)),
    )
    .map_err(db)?;
    let original_members = committed(tx, family)?;
    let (rows, total) = projected(tx, family)?;
    if budget != original || held > budget || held != total || original_members != rows {
        return Err(conflict());
    }
    Ok(())
}
