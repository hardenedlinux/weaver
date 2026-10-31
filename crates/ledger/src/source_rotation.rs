//! Exact source handoff results and non-reusable public keys share the deciding store.
use crate::{Ledger, source_authority as authority, store::db};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use weaver_contracts::{
    Error, MAX_CREDITS, Result, SourceAuthority, SourceIdentity, SourceRotation,
    SourceRotationOutcome, SourceRotationReceipt,
};

fn lookup(
    connection: &Connection,
    caller: &SourceIdentity,
    command: &SourceRotation,
    digest: &str,
    current: &SourceAuthority,
) -> Result<Option<SourceRotationReceipt>> {
    let record: Option<(String, String, String, String)> = connection
        .query_row(
            "SELECT digest,proposer,command,receipt FROM source_rotations WHERE operation_id=?1",
            [&command.operation_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .optional()
        .map_err(db)?;
    record
        .map(|(bound, proposer, encoded, receipt)| {
            let original: SourceRotation = weaver_contracts::decode(encoded.as_bytes())?;
            let proposer: SourceIdentity = weaver_contracts::decode(proposer.as_bytes())?;
            let receipt: SourceRotationReceipt = weaver_contracts::decode(receipt.as_bytes())?;
            receipt.validate_for(command)?;
            if original != *command
                || original.digest()? != bound
                || bound != digest
                || receipt.operation_id != command.operation_id
                || receipt.digest != bound
            {
                return Err(Error::Conflict("source rotation identity already bound"));
            }
            if *caller != proposer && *caller != current.identity {
                return Err(Error::Denied);
            }
            Ok(receipt)
        })
        .transpose()
}

impl Ledger {
    /// Caller identity is verified by the RPC host, never read from command labels.
    /// An original proposer may observe its exact durable result after retirement;
    /// this cannot install a new binding or authorize any other source operation.
    pub fn rotate_source_authority(
        &mut self,
        caller: &SourceIdentity,
        command: &SourceRotation,
    ) -> Result<SourceRotationReceipt> {
        caller.validate()?;
        let digest = command.digest()?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        let current = authority::current(&tx)?.ok_or(Error::Denied)?;
        if let Some(receipt) = lookup(&tx, caller, command, &digest, &current)? {
            return Ok(receipt);
        }
        authority::require(&tx, Some(caller))?;
        let used:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM source_keys WHERE public_key_sha256=?1 OR certificate_sha256=?2)",params![command.next.public_key_sha256,command.next.certificate_sha256],|r|r.get(0)).map_err(db)?;
        let (outcome, after) =
            if command.expected_epoch == current.epoch && current.epoch < MAX_CREDITS && !used {
                let next = SourceAuthority {
                    epoch: current.epoch + 1,
                    identity: command.next.clone(),
                };
                authority::write(&tx, &next)?;
                (SourceRotationOutcome::Committed, next)
            } else {
                (SourceRotationOutcome::Rejected, current)
            };
        let receipt = SourceRotationReceipt {
            operation_id: command.operation_id.clone(),
            digest,
            outcome,
            authority: after,
        };
        tx.execute(
            "INSERT INTO source_rotations VALUES(?1,?2,?3,?4,?5)",
            params![
                command.operation_id,
                receipt.digest,
                serde_json::to_string(caller)?,
                serde_json::to_string(command)?,
                serde_json::to_string(&receipt)?
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(receipt)
    }
}
