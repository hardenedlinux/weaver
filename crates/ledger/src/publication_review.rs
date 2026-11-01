//! Local deciding-store review admission. The native caller is the trusted review host.
//! Independent registry recovery, producer authentication and Delta validity are premises.
#[cfg(test)]
#[path = "../tests/unit/publication_review_storage.rs"]
mod tests;
use crate::{
    Ledger, publication, publication_barrier,
    store::{db, integer},
};
use weaver_contracts::{
    AuthorityParent, Error, Publication, PublicationKey, PublicationReview, Result, body_digest,
};

pub(crate) fn parent(
    connection: &crate::persistence::driver::Connection,
) -> Result<Option<AuthorityParent>> {
    crate::persistence::maybe(connection, "SELECT revision,fence,policy,(SELECT schema FROM authority_schema WHERE singleton=1) FROM authority WHERE singleton=1", (), |row| Ok(AuthorityParent {
            revision: integer(row,0)?, fence: integer(row,1)?,
            policy_digest: body_digest(&row.get::<String>(2)?),
            schema_digest: row.get::<Option<String>>(3)?.map(|s| body_digest(&s)),
        })).map_err(db)
}

fn requirement(
    connection: &crate::persistence::driver::Connection,
    key: &PublicationKey,
) -> Result<Option<String>> {
    let record: Option<(String, String)> = crate::persistence::maybe(
        connection,
        "SELECT digest,parent FROM authority_review_requirements WHERE operation_id=?1",
        crate::persistence::params![key.operation_id.to_owned()],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )
    .map_err(db)?;
    record
        .map(|(digest, parent)| {
            if digest != key.digest {
                return Err(Error::Conflict("review command binding"));
            }
            Ok(parent)
        })
        .transpose()
}

fn registered(
    connection: &crate::persistence::driver::Connection,
    key: &PublicationKey,
) -> Result<Option<PublicationReview>> {
    let record: Option<(String, String, String)> = crate::persistence::maybe(
        connection,
        "SELECT digest,artifact_digest,record FROM authority_reviews WHERE operation_id=?1",
        crate::persistence::params![key.operation_id.to_owned()],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    )
    .map_err(db)?;
    record
        .map(|(digest, artifact_digest, record)| {
            let review: PublicationReview = weaver_contracts::decode(record.as_bytes())?;
            if digest != key.digest
                || review.publication != *key
                || review.digest()? != artifact_digest
            {
                return Err(Error::Conflict("review record binding"));
            }
            Ok(review)
        })
        .transpose()
}

/// Called inside the publication transaction, before authority mutation.
pub(crate) fn require_approved(
    connection: &crate::persistence::driver::Connection,
    key: &PublicationKey,
) -> Result<()> {
    let Some(encoded) = requirement(connection, key)? else {
        return Ok(());
    };
    let captured: Option<AuthorityParent> = weaver_contracts::decode(encoded.as_bytes())?;
    let review = registered(connection, key)?.ok_or(Error::Conflict("approved review missing"))?;
    if review.parent != captured || parent(connection)? != captured {
        return Err(Error::Conflict("review parent changed"));
    }
    Ok(())
}

impl Ledger {
    /// Recompute SPEC schema-bound replay before trusted-host review admission.
    /// This adds concrete candidate checks, not producer authentication or no-gain.
    /// The deciding registration transaction still rechecks the original parent.
    pub fn register_replay_checked_review(
        &mut self,
        change: &Publication,
        review: &PublicationReview,
    ) -> Result<String> {
        let parent = self.required_review_parent(&review.publication)?;
        weaver_policy::verify_publication_replay(change, review, parent.as_ref())?;
        self.register_approved_review(review)
    }
    /// Atomically latch mandatory review and stage the original command. No downgrade exists.
    /// Historical unreviewed decisions cannot be retroactively represented as reviewed.
    pub fn stage_reviewed_authority(&mut self, change: &Publication) -> Result<PublicationKey> {
        let digest = change.digest()?;
        weaver_policy::validate_typed(&change.policy, &change.schema)?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        publication_barrier::require_binding(&tx, change)?;
        let key = PublicationKey {
            operation_id: change.operation_id.clone(),
            digest,
        };
        let existing = requirement(&tx, &key)?;
        let decided = publication::lookup(&tx, &key.operation_id, &key.digest)?.is_some();
        if existing.is_none() {
            if decided {
                return Err(Error::Conflict("unreviewed decision already final"));
            }
            crate::persistence::exec(
                &tx,
                "INSERT INTO authority_review_requirements VALUES(?1,?2,?3)",
                crate::persistence::params![
                    (key.operation_id).to_owned(),
                    (key.digest).to_owned(),
                    (serde_json::to_string(&parent(&tx)?)?).to_owned()
                ],
            )
            .map_err(db)?;
        }
        if !decided {
            crate::persistence::exec(&tx, "INSERT INTO authority_pending VALUES(?1,?2,?3) ON CONFLICT(operation_id) DO NOTHING", crate::persistence::params![(key.operation_id).to_owned(),(key.digest).to_owned(),(serde_json::to_string(change)?).to_owned()]).map_err(db)?;
        }
        tx.commit().map_err(db)?;
        Ok(key)
    }

    /// The captured parent comes from the deciding store, never from the candidate.
    pub fn required_review_parent(&self, key: &PublicationKey) -> Result<Option<AuthorityParent>> {
        key.validate()?;
        let encoded =
            requirement(&self.connection, key)?.ok_or(Error::Conflict("review not required"))?;
        weaver_contracts::decode(encoded.as_bytes())
    }

    /// Trusted host admission only: callers must already authenticate the producer,
    /// verify its upstream Delta/replay contract and establish current source cuts.
    /// This function provides immutable local registration, not those semantic proofs.
    pub fn register_approved_review(&mut self, review: &PublicationReview) -> Result<String> {
        let digest = review.digest()?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let encoded =
            requirement(&tx, &review.publication)?.ok_or(Error::Conflict("review not required"))?;
        let captured: Option<AuthorityParent> = weaver_contracts::decode(encoded.as_bytes())?;
        if captured != review.parent {
            return Err(Error::Conflict("review original parent binding"));
        }
        if let Some(original) = registered(&tx, &review.publication)? {
            if original != *review {
                return Err(Error::Conflict("review already bound"));
            }
        } else {
            register_current(&tx, review, &digest)?;
        }
        tx.commit().map_err(db)?;
        Ok(digest)
    }

    /// Historical observation cannot activate a proposal or release a reservation.
    pub fn publication_review(&self, key: &PublicationKey) -> Result<Option<PublicationReview>> {
        key.validate()?;
        registered(&self.connection, key)
    }
}

fn register_current(
    connection: &crate::persistence::driver::Connection,
    review: &PublicationReview,
    digest: &str,
) -> Result<()> {
    let pending: Option<String> = crate::persistence::maybe(
        connection,
        "SELECT proposal FROM authority_pending WHERE operation_id=?1 AND digest=?2",
        crate::persistence::params![
            (review.publication.operation_id).to_owned(),
            (review.publication.digest).to_owned()
        ],
        |row| row.get(0),
    )
    .map_err(db)?;
    let proposal: Publication = weaver_contracts::decode(
        pending
            .ok_or(Error::Conflict("original review intent missing"))?
            .as_bytes(),
    )?;
    if proposal.digest()? != review.publication.digest
        || parent(connection)? != review.parent
        || proposal.expected_revision != review.parent.as_ref().map(|p| p.revision)
        || review
            .parent
            .as_ref()
            .is_some_and(|p| proposal.fence < p.fence)
    {
        return Err(Error::Conflict("review deciding parent changed"));
    }
    crate::persistence::exec(
        connection,
        "INSERT INTO authority_reviews VALUES(?1,?2,?3,?4)",
        crate::persistence::params![
            (review.publication.operation_id).to_owned(),
            (review.publication.digest).to_owned(),
            (digest).to_owned(),
            (serde_json::to_string(review)?).to_owned()
        ],
    )
    .map_err(db)?;
    Ok(())
}
