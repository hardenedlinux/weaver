//! One transaction binds original publication identity, authority/schema and immutable outcome.
use crate::{
    Ledger,
    store::{db, integer},
};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
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

pub(crate) fn apply(tx: &Transaction<'_>, change: AuthorityChange<'_>) -> Result<Decision> {
    let current: Option<Head> = tx
        .query_row(
            "SELECT revision,fence FROM authority WHERE singleton=1",
            [],
            |row| {
                Ok(Head {
                    revision: integer(row, 0)?,
                    fence: integer(row, 1)?,
                })
            },
        )
        .optional()
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
    tx.execute("INSERT INTO authority VALUES(1,?1,?2,?3) ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,fence=excluded.fence,policy=excluded.policy",
        params![revision as i64,change.fence as i64,change.policy]).map_err(db)?;
    if let Some(schema) = change.schema {
        tx.execute("INSERT INTO authority_schema VALUES(1,?1) ON CONFLICT(singleton) DO UPDATE SET schema=excluded.schema",[schema]).map_err(db)?;
    } else {
        tx.execute("DELETE FROM authority_schema", []).map_err(db)?;
    }
    Ok(Decision {
        outcome: PublicationOutcome::Committed,
        head: Some(Head {
            revision,
            fence: change.fence,
        }),
    })
}

fn lookup(
    connection: &Connection,
    operation_id: &str,
    digest: &str,
) -> Result<Option<PublicationReceipt>> {
    let record: Option<(String, String)> = connection
        .query_row(
            "SELECT digest,receipt FROM authority_publications WHERE operation_id=?1",
            [operation_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
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

impl Ledger {
    /// Exact retries observe their original committed or rejected outcome; never rebase a CAS.
    pub fn publish_authority(&mut self, change: &Publication) -> Result<PublicationReceipt> {
        let digest = change.digest()?;
        if let Some(receipt) = lookup(&self.connection, &change.operation_id, &digest)? {
            return Ok(receipt);
        }
        weaver_policy::validate_typed(&change.policy, &change.schema)?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        if let Some(receipt) = lookup(&tx, &change.operation_id, &digest)? {
            return Ok(receipt);
        }
        let decision = apply(
            &tx,
            AuthorityChange {
                expected: change.expected_revision,
                policy: &change.policy,
                schema: Some(&change.schema),
                fence: change.fence,
            },
        )?;
        let receipt = PublicationReceipt {
            operation_id: change.operation_id.clone(),
            digest: digest.clone(),
            outcome: decision.outcome,
            revision: decision.head.as_ref().map(|h| h.revision),
            fence: decision.head.as_ref().map(|h| h.fence),
        };
        receipt.validate()?;
        tx.execute(
            "INSERT INTO authority_publications VALUES(?1,?2,?3,?4)",
            params![
                change.operation_id,
                digest,
                serde_json::to_string(change)?,
                serde_json::to_string(&receipt)?
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(receipt)
    }
    /// Read a historical decision. Absence is not abort and cannot release any hold.
    pub fn publication_receipt(&self, key: &PublicationKey) -> Result<Option<PublicationReceipt>> {
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
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
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
