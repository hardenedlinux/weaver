// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Independently retained append-only OAuth authority journal.
use crate::{
    persistence::{self, WriteScope, driver::Connection},
    store::{db, integer},
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
};
use weaver_contracts::{
    Error, ProviderOAuthDeployment, ProviderOAuthIssuerRotation, Result, body_digest, oauth_hex,
};

const LIMIT: usize = 8 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) enum Change {
    Genesis(String),
    Revoke(String),
    Rotate(ProviderOAuthIssuerRotation),
}

fn prefix(connection: &Connection) -> Result<Option<(u64, String)>> {
    persistence::maybe(
        connection,
        "SELECT length,digest FROM provider_oauth_witness WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, r.get(1)?)),
    )
    .map_err(db)
}

fn storage(error: std::io::Error) -> Error {
    Error::Storage(format!("OAuth witness: {}", error.kind()))
}

pub(crate) fn require_current(
    connection: &Connection,
    config: &ProviderOAuthDeployment,
) -> Result<()> {
    if let Some(path) = &config.witness_file {
        let (length, _) = prefix(connection)?.ok_or(Error::Denied)?;
        let metadata = std::fs::symlink_metadata(path).map_err(storage)?;
        if !metadata.is_file() || metadata.len() != length {
            return Err(Error::Conflict("OAuth witness requires reconciliation"));
        }
    }
    Ok(())
}

fn retain(tx: &WriteScope<'_>, image: &str) -> Result<()> {
    persistence::exec(tx,
        "INSERT INTO provider_oauth_witness VALUES(1,?1,?2) ON CONFLICT(singleton) DO UPDATE SET length=excluded.length,digest=excluded.digest",
        persistence::params![image.len() as i64, body_digest(image)],
    ).map_err(db)?;
    Ok(())
}

fn append(file: &mut File, image: &mut String, change: &Change) -> Result<()> {
    let mut record = serde_json::to_string(change)?;
    record.push('\n');
    if image.len() + record.len() > LIMIT {
        return Err(Error::Conflict("OAuth witness capacity"));
    }
    file.write_all(record.as_bytes()).map_err(storage)?;
    file.sync_all().map_err(storage)?;
    image.push_str(&record);
    Ok(())
}

/// Reconcile a retained prefix before startup or a source change. An appended
/// record is authoritative even when the subsequent database response was lost.
pub(crate) fn apply(
    tx: &WriteScope<'_>,
    config: &ProviderOAuthDeployment,
    change: Option<Change>,
) -> Result<()> {
    let Some(path) = &config.witness_file else {
        return match change {
            None => Ok(()),
            Some(Change::Revoke(hash)) => apply_revocation(tx, &hash).map(|_| ()),
            _ => Err(Error::Conflict(
                "issuer rotation requires an independent OAuth witness",
            )),
        };
    };
    if !std::fs::symlink_metadata(path).map_err(storage)?.is_file() {
        return Err(Error::Invalid(
            "OAuth witness must be a provisioned regular file",
        ));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .append(true)
        .open(path)
        .map_err(storage)?;
    file.try_lock()
        .map_err(|_| Error::Conflict("OAuth witness has another writer"))?;
    let mut image = String::new();
    (&mut file)
        .take((LIMIT + 1) as u64)
        .read_to_string(&mut image)
        .map_err(storage)?;
    if image.len() > LIMIT {
        return Err(Error::Conflict("OAuth witness capacity"));
    }
    let prior = prefix(tx)?;
    let needs_seed = prior.is_none();
    let genesis = body_digest(&serde_json::to_string(config)?);
    if image.is_empty() && prior.is_none() {
        append(&mut file, &mut image, &Change::Genesis(genesis.clone()))?;
    }
    if !image.ends_with('\n') {
        return Err(Error::Conflict("OAuth witness has an incomplete record"));
    }
    let (header, _) = image.split_once('\n').ok_or(Error::Denied)?;
    if !matches!(weaver_contracts::decode::<Change>(header.as_bytes())?, Change::Genesis(binding) if binding == genesis)
    {
        return Err(Error::Conflict("OAuth witness deployment differs"));
    }
    let start = if let Some((length, digest)) = prior {
        let length = usize::try_from(length).map_err(|_| Error::Denied)?;
        let known = image
            .get(..length)
            .ok_or(Error::Conflict("OAuth witness rolled back"))?;
        if length <= header.len() || !known.ends_with('\n') || body_digest(known) != digest {
            return Err(Error::Conflict("OAuth witness prefix differs"));
        }
        length
    } else {
        header.len() + 1
    };
    if start < image.len() {
        // A previous append may have written the record and lost its sync result.
        // Persist that suffix before any database commit can acknowledge it.
        file.sync_all().map_err(storage)?;
    }
    let mut seeded = std::collections::BTreeSet::new();
    for line in image[start..].lines() {
        let record = weaver_contracts::decode(line.as_bytes())?;
        project(tx, config, &record)?;
        if needs_seed && let Change::Revoke(hash) = record {
            seeded.insert(hash);
        }
    }
    // Before first activation, also retain tombstones created by the direct profile.
    if needs_seed {
        let retained = persistence::read_all(
            tx,
            "SELECT token_hash FROM provider_oauth_revocations ORDER BY token_hash",
            (),
            |row| row.get::<String>(0),
        )
        .map_err(db)?;
        for hash in retained {
            if !seeded.contains(&hash) {
                append(&mut file, &mut image, &Change::Revoke(hash))?;
            }
        }
    }
    if let Some(change) = change
        && project(tx, config, &change)?
    {
        append(&mut file, &mut image, &change)?;
    }
    retain(tx, &image)
}

pub(super) fn issuer_key(
    connection: &Connection,
    config: &ProviderOAuthDeployment,
) -> Result<(u64, String)> {
    Ok(persistence::maybe(
        connection,
        "SELECT epoch,public_key FROM provider_oauth_issuer_rotations ORDER BY epoch DESC LIMIT 1",
        (),
        |r| Ok((integer(r, 0)?, r.get(1)?)),
    )
    .map_err(db)?
    .unwrap_or_else(|| (0, config.public_key.clone())))
}

fn apply_revocation(connection: &Connection, hash: &str) -> Result<bool> {
    oauth_hex(hash, 64)?;
    Ok(persistence::exec(
        connection,
        "INSERT INTO provider_oauth_revocations VALUES(?1) ON CONFLICT DO NOTHING",
        persistence::params![hash.to_owned()],
    )
    .map_err(db)?
        == 1)
}

fn apply_rotation(
    connection: &Connection,
    config: &ProviderOAuthDeployment,
    rotation: &ProviderOAuthIssuerRotation,
) -> Result<bool> {
    let next = rotation
        .expected_epoch
        .checked_add(1)
        .and_then(|n| i64::try_from(n).ok())
        .ok_or(Error::Denied)?;
    let encoded = serde_json::to_string(rotation)?;
    let previous: Option<String> = persistence::maybe(
        connection,
        "SELECT record FROM provider_oauth_issuer_rotations WHERE epoch=?1",
        persistence::params![next],
        |row| row.get(0),
    )
    .map_err(db)?;
    if let Some(previous) = previous {
        return if previous == encoded {
            Ok(false)
        } else {
            Err(Error::Denied)
        };
    }
    let (epoch, key) = issuer_key(connection, config)?;
    if epoch != rotation.expected_epoch
        || rotation.public_key == key
        || rotation.public_key == config.public_key
    {
        return Err(Error::Denied);
    }
    let retired = persistence::one(
        connection,
        "SELECT EXISTS(SELECT 1 FROM provider_oauth_issuer_rotations WHERE public_key=?1)",
        persistence::params![rotation.public_key.clone()],
        |row| row.get::<bool>(0),
    )
    .map_err(db)?;
    if retired {
        return Err(Error::Denied);
    }
    weaver_policy::verify_provider_oauth_rotation(&config.issuer, &key, rotation)?;
    persistence::exec(
        connection,
        "INSERT INTO provider_oauth_issuer_rotations VALUES(?1,?2,?3)",
        persistence::params![next, rotation.public_key.clone(), encoded],
    )
    .map_err(db)?;
    Ok(true)
}

fn project(tx: &WriteScope<'_>, config: &ProviderOAuthDeployment, record: &Change) -> Result<bool> {
    match record {
        Change::Genesis(_) => Err(Error::Conflict("unexpected OAuth witness genesis")),
        Change::Revoke(hash) => apply_revocation(tx, hash),
        Change::Rotate(rotation) => apply_rotation(tx, config, rotation),
    }
}

#[cfg(test)]
#[path = "../tests/unit/provider_oauth_witness.rs"]
mod tests;
