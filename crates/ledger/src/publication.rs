// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One transaction binds original publication identity, authority/schema and immutable outcome.
use crate::persistence::WriteScope;
use crate::{
    Ledger,
    store::{db, integer},
};
use weaver_contracts::{
    Error, Publication, PublicationKey, PublicationOutcome, PublicationReceipt, Result,
};

pub(crate) struct AuthorityChange<'a> {
    pub expected: Option<u64>,
    pub policy: &'a str,
    pub schema: Option<&'a str>,
    pub fence: u64,
}
pub(crate) struct Head {
    pub revision: u64,
    pub fence: u64,
}
pub(crate) struct Decision {
    pub outcome: PublicationOutcome,
    pub head: Option<Head>,
}

pub(crate) fn apply(tx: &WriteScope<'_>, change: AuthorityChange<'_>) -> Result<Decision> {
    let current: Option<Head> = crate::persistence::maybe(
        tx,
        "SELECT revision,fence FROM authority WHERE singleton=1",
        (),
        |row| {
            Ok(Head {
                revision: integer(row, 0)?,
                fence: integer(row, 1)?,
            })
        },
    )
    .map_err(db)?;
    let revision = match (&current, change.expected) {
        (None, None) => 0,
        (Some(head), Some(expected))
            if head.revision == expected
                && change.fence >= head.fence
                && head.revision < i64::MAX as u64 =>
        {
            head.revision + 1
        }
        _ => {
            return Ok(Decision {
                outcome: PublicationOutcome::Rejected,
                head: current,
            });
        }
    };
    crate::persistence::exec(tx, "INSERT INTO authority VALUES(1,?1,?2,?3) ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,fence=excluded.fence,policy=excluded.policy", crate::persistence::params![(revision as i64).to_owned(),(change.fence as i64).to_owned(),(change.policy).to_owned()]).map_err(db)?;
    if let Some(schema) = change.schema {
        crate::persistence::exec(tx, "INSERT INTO authority_schema VALUES(1,?1) ON CONFLICT(singleton) DO UPDATE SET schema=excluded.schema", crate::persistence::params![(schema).to_owned()]).map_err(db)?;
    } else {
        crate::persistence::exec(tx, "DELETE FROM authority_schema", ()).map_err(db)?;
    }
    Ok(Decision {
        outcome: PublicationOutcome::Committed,
        head: Some(Head {
            revision,
            fence: change.fence,
        }),
    })
}

pub(crate) fn lookup(
    connection: &crate::persistence::driver::Connection,
    operation_id: &str,
    digest: &str,
) -> Result<Option<PublicationReceipt>> {
    let record: Option<(String, String)> = crate::persistence::maybe(
        connection,
        "SELECT digest,receipt FROM authority_publications WHERE operation_id=?1",
        crate::persistence::params![(operation_id).to_owned()],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .map_err(db)?;
    record
        .map(|(bound, encoded)| {
            if bound != digest {
                return Err(Error::Conflict("publication ID already bound"));
            }
            let receipt: PublicationReceipt = serde_json::from_str(&encoded)?;
            receipt.validate()?;
            if receipt.operation_id != operation_id || receipt.digest != bound {
                return Err(Error::Conflict("publication result binding"));
            }
            Ok(receipt)
        })
        .transpose()
}

fn record_decision(
    tx: &WriteScope<'_>,
    change: &Publication,
    digest: &str,
    decision: Decision,
) -> Result<PublicationReceipt> {
    let receipt = PublicationReceipt {
        operation_id: change.operation_id.clone(),
        digest: digest.into(),
        outcome: decision.outcome,
        revision: decision.head.as_ref().map(|h| h.revision),
        fence: decision.head.as_ref().map(|h| h.fence),
    };
    receipt.validate()?;
    crate::persistence::exec(
        tx,
        "INSERT INTO authority_publications VALUES(?1,?2,?3,?4)",
        crate::persistence::params![
            (change.operation_id).to_owned(),
            (digest).to_owned(),
            (serde_json::to_string(change)?).to_owned(),
            (serde_json::to_string(&receipt)?).to_owned()
        ],
    )
    .map_err(db)?;
    crate::persistence::exec(
        tx,
        "DELETE FROM authority_pending WHERE operation_id=?1 AND digest=?2",
        crate::persistence::params![(change.operation_id).to_owned(), (digest).to_owned()],
    )
    .map_err(db)?;
    Ok(receipt)
}

fn decide_publication(
    tx: &WriteScope<'_>,
    change: &Publication,
    digest: &str,
    caller: Option<&weaver_contracts::SourceIdentity>,
) -> Result<PublicationReceipt> {
    crate::source_authority::require(tx, caller)?;
    crate::publication_barrier::require_binding(tx, change)?;
    if let Some(receipt) = lookup(tx, &change.operation_id, digest)? {
        return Ok(receipt);
    }
    let review = crate::publication_review::require_approved(
        tx,
        &PublicationKey {
            operation_id: change.operation_id.clone(),
            digest: digest.into(),
        },
    );
    let delta = crate::delta_registration::require_current(
        tx,
        &PublicationKey {
            operation_id: change.operation_id.clone(),
            digest: digest.into(),
        },
    );
    let decision = apply(
        tx,
        AuthorityChange {
            expected: change.expected_revision,
            policy: &change.policy,
            schema: Some(&change.schema),
            fence: change.fence,
        },
    )?;
    let evidence = if decision.outcome == PublicationOutcome::Committed {
        review?;
        delta?
    } else {
        None
    };
    let receipt = record_decision(tx, change, digest, decision)?;
    if let Some(evidence) = evidence {
        crate::reviewed_head::bind(tx, &receipt, &evidence)?;
    }
    Ok(receipt)
}

impl Ledger {
    /// Exact retries observe their original committed or rejected outcome; never rebase a CAS.
    pub fn publish_authority(&mut self, change: &Publication) -> Result<PublicationReceipt> {
        crate::source_authority::require(&self.connection, self.source.as_ref())?;
        let digest = change.digest()?;
        crate::publication_barrier::require_binding(&self.connection, change)?;
        if let Some(receipt) = lookup(&self.connection, &change.operation_id, &digest)? {
            return Ok(receipt);
        }
        weaver_policy::validate_typed(&change.policy, &change.schema)?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        let receipt = decide_publication(&tx, change, &digest, self.source.as_ref())?;
        tx.commit().map_err(db)?;
        Ok(receipt)
    }
    /// Read a historical decision. Absence is not abort and cannot release any hold.
    pub fn publication_receipt(&self, key: &PublicationKey) -> Result<Option<PublicationReceipt>> {
        crate::source_authority::require(&self.connection, self.source.as_ref())?;
        key.validate()?;
        lookup(&self.connection, &key.operation_id, &key.digest)
    }
    /// Typed native source API shares the same deciding update as durable RPC publications.
    pub fn publish_typed(
        &mut self,
        expected: Option<u64>,
        source: &str,
        schema: &str,
        fence: u64,
    ) -> Result<u64> {
        weaver_policy::validate_typed(source, schema)?;
        self.update_authority(AuthorityChange {
            expected,
            policy: source,
            schema: Some(schema),
            fence,
        })
    }
    pub(crate) fn update_authority(&mut self, change: AuthorityChange<'_>) -> Result<u64> {
        if change.fence > i64::MAX as u64 {
            return Err(Error::Invalid("fence"));
        }
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        crate::source_authority::require(&tx, self.source.as_ref())?;
        let decision = apply(&tx, change)?;
        if decision.outcome != PublicationOutcome::Committed {
            return Err(Error::Conflict("publication CAS or fence"));
        }
        let head = decision
            .head
            .ok_or(Error::Conflict("publication head missing"))?;
        tx.commit().map_err(db)?;
        Ok(head.revision)
    }
}

#[cfg(test)]
#[path = "../tests/unit/publication.rs"]
mod tests;
