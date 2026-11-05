// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One immutable profile identity; registration shares the original task transaction.
use crate::persistence::WriteScope;
use crate::store::db;
use weaver_contracts::{Error, ProviderPlan, ProviderProfile, Result};

const PROFILE_FLOOR_QUERY: &str = "SELECT EXISTS(
  SELECT 1 FROM tasks INDEXED BY task_profile_semantics
  WHERE json_type(record,'$.provider_profile') IS NOT NULL AND json_type(record,'$.provider_profile') != 'null'
    AND json_extract(record,'$.profile')=?1
    AND json_array(json_extract(record,'$.provider_profile.id'),json_extract(record,'$.provider_profile.protocol'),
      json_extract(record,'$.provider_profile.max_output_tokens'),json_extract(record,'$.provider_profile.max_messages'),
      json_extract(record,'$.provider_profile.max_body_bytes'),
      json_remove(json_extract(record,'$.provider_profile'),'$.id','$.protocol','$.max_output_tokens','$.max_messages','$.max_body_bytes')) < ?2
  ) OR EXISTS(
  SELECT 1 FROM tasks INDEXED BY task_profile_semantics
  WHERE json_type(record,'$.provider_profile') IS NOT NULL AND json_type(record,'$.provider_profile') != 'null'
    AND json_extract(record,'$.profile')=?1
    AND json_array(json_extract(record,'$.provider_profile.id'),json_extract(record,'$.provider_profile.protocol'),
      json_extract(record,'$.provider_profile.max_output_tokens'),json_extract(record,'$.provider_profile.max_messages'),
      json_extract(record,'$.provider_profile.max_body_bytes'),
      json_remove(json_extract(record,'$.provider_profile'),'$.id','$.protocol','$.max_output_tokens','$.max_messages','$.max_body_bytes')) > ?2)";

pub(crate) fn register(tx: &WriteScope<'_>, profile: &ProviderProfile) -> Result<()> {
    let digest = profile.digest()?;
    let record = serde_json::to_string(profile)?;
    require_floor(tx, &profile.id, &floor_key(profile)?)?;
    let old: Option<(String, String)> = crate::persistence::maybe(
        tx,
        "SELECT digest,record FROM provider_profiles WHERE id=?1",
        crate::persistence::params![profile.id.to_owned()],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .map_err(db)?;
    if let Some((bound, original)) = old {
        let original: ProviderProfile = weaver_contracts::decode(original.as_bytes())?;
        if bound != digest || original != *profile {
            return Err(Error::Conflict("profile identity already bound"));
        }
    } else {
        crate::persistence::exec(
            tx,
            "INSERT INTO provider_profiles VALUES(?1,?2,?3)",
            crate::persistence::params![
                (profile.id).to_owned(),
                (digest).to_owned(),
                (record).to_owned()
            ],
        )
        .map_err(db)?;
    }
    Ok(())
}

/// Exact immutable registry bytes plus their validated semantic index key.
pub(crate) struct CheckedProfile {
    record: String,
    floor: String,
}

impl CheckedProfile {
    pub(crate) fn require_current(&self, tx: &WriteScope<'_>, plan: &ProviderPlan) -> Result<()> {
        let matches: bool = crate::persistence::one(
            tx,
            "SELECT EXISTS(SELECT 1 FROM provider_profiles WHERE id=?1 AND digest=?2 AND record=?3)",
            [plan.profile.as_str(), plan.profile_commitment.as_str(), self.record.as_str()],
            |row| row.get(0),
        ).map_err(db)?;
        if !matches {
            return Err(Error::Conflict(
                "profile registry does not match original commitment",
            ));
        }
        require_floor(tx, &plan.profile, &self.floor)
    }
}

pub(crate) fn require(
    connection: &crate::persistence::driver::Connection,
    plan: &ProviderPlan,
) -> Result<CheckedProfile> {
    let id = plan.profile.as_str();
    let expected = plan.profile_commitment.as_str();
    let (bound, record): (String, String) = crate::persistence::one(
        connection,
        "SELECT digest,record FROM provider_profiles WHERE id=?1",
        crate::persistence::params![(id).to_owned()],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .map_err(db)?;
    let profile: ProviderProfile = weaver_contracts::decode(record.as_bytes())?;
    if bound != expected || profile.id != id || profile.digest()? != expected {
        return Err(Error::Conflict(
            "profile registry does not match original commitment",
        ));
    }
    let floor = floor_key(&profile)?;
    require_floor(connection, id, &floor)?;
    Ok(CheckedProfile { record, floor })
}

// Original tasks retain the semantic floor even if a registry projection is lost.
// Two composite-index range seeks detect conflicting canonical artifacts without
// scanning every task sharing a popular profile. No request payload is rewritten.
fn floor_key(profile: &ProviderProfile) -> Result<String> {
    // The residual object makes even unknown null-valued fields incompatible.
    // Known fields have stable order independent of JSON formatting.
    Ok(serde_json::to_string(&(
        &profile.id,
        &profile.protocol,
        profile.max_output_tokens,
        profile.max_messages,
        profile.max_body_bytes,
        serde_json::json!({}),
    ))?)
}

fn require_floor(
    connection: &crate::persistence::driver::Connection,
    id: &str,
    key: &str,
) -> Result<()> {
    let conflict: bool =
        crate::persistence::one(connection, PROFILE_FLOOR_QUERY, [id, key], |row| row.get(0))
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
