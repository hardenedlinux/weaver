//! One immutable profile identity; registration shares the original task transaction.
use crate::store::db;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use weaver_contracts::{Error, ProviderPlan, ProviderProfile, Result};

const PROFILE_FLOOR_QUERY: &str = "SELECT EXISTS(
  SELECT 1 FROM tasks INDEXED BY task_profile_semantics
  WHERE json_type(record,'$.provider_profile') IS NOT NULL AND json_type(record,'$.provider_profile') != 'null'
    AND json_extract(record,'$.profile')=?1
    AND json_array(json_extract(record,'$.provider_profile.id'),json_extract(record,'$.provider_profile.protocol'),
      json_extract(record,'$.provider_profile.max_output_tokens'),json_extract(record,'$.provider_profile.max_messages'),
      json_extract(record,'$.provider_profile.max_body_bytes'),
      json_remove(json_extract(record,'$.provider_profile'),'$.id','$.protocol','$.max_output_tokens','$.max_messages','$.max_body_bytes')) < ?2
  UNION ALL
  SELECT 1 FROM tasks INDEXED BY task_profile_semantics
  WHERE json_type(record,'$.provider_profile') IS NOT NULL AND json_type(record,'$.provider_profile') != 'null'
    AND json_extract(record,'$.profile')=?1
    AND json_array(json_extract(record,'$.provider_profile.id'),json_extract(record,'$.provider_profile.protocol'),
      json_extract(record,'$.provider_profile.max_output_tokens'),json_extract(record,'$.provider_profile.max_messages'),
      json_extract(record,'$.provider_profile.max_body_bytes'),
      json_remove(json_extract(record,'$.provider_profile'),'$.id','$.protocol','$.max_output_tokens','$.max_messages','$.max_body_bytes')) > ?2)";

pub(crate) fn register(tx: &Transaction<'_>, profile: &ProviderProfile) -> Result<()> {
    let digest = profile.digest()?;
    let record = serde_json::to_string(profile)?;
    require_floors(tx, profile)?;
    let old: Option<(String, String)> = tx
        .query_row(
            "SELECT digest,record FROM provider_profiles WHERE id=?1",
            [&profile.id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(db)?;
    if let Some((bound, original)) = old {
        let original: ProviderProfile = weaver_contracts::decode(original.as_bytes())?;
        if bound != digest || original != *profile {
            return Err(Error::Conflict("profile identity already bound"));
        }
    } else {
        tx.execute(
            "INSERT INTO provider_profiles VALUES(?1,?2,?3)",
            params![profile.id, digest, record],
        )
        .map_err(db)?;
    }
    Ok(())
}

pub(crate) fn require(connection: &Connection, plan: &ProviderPlan) -> Result<()> {
    let id = plan.profile.as_str();
    let expected = plan.profile_commitment.as_str();
    let (bound, record): (String, String) = connection
        .query_row(
            "SELECT digest,record FROM provider_profiles WHERE id=?1",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(db)?;
    let profile: ProviderProfile = weaver_contracts::decode(record.as_bytes())?;
    if bound != expected || profile.id != id || profile.digest()? != expected {
        return Err(Error::Conflict(
            "profile registry does not match original commitment",
        ));
    }
    require_floors(connection, &profile)?;
    Ok(())
}

// Original tasks retain the semantic floor even if a registry projection is lost.
// Two composite-index range seeks detect conflicting canonical artifacts without
// scanning every task sharing a popular profile. No request payload is rewritten.
fn require_floors(connection: &Connection, profile: &ProviderProfile) -> Result<()> {
    // The residual object makes even unknown null-valued fields incompatible.
    // Known fields have stable order independent of JSON formatting.
    let key = serde_json::to_string(&(
        &profile.id,
        &profile.protocol,
        profile.max_output_tokens,
        profile.max_messages,
        profile.max_body_bytes,
        serde_json::json!({}),
    ))?;
    let conflict: bool = connection
        .query_row(PROFILE_FLOOR_QUERY, params![profile.id, key], |row| {
            row.get(0)
        })
        .map_err(db)?;
    if conflict {
        return Err(Error::Conflict(
            "original task retains another profile commitment",
        ));
    }
    Ok(())
}

#[cfg(test)]
#[path = "../tests/unit/profile_floor_plan.rs"]
mod plan_tests;
