// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Exact source handoff results and non-reusable public keys share the deciding store.
use crate::{Ledger, source_authority as authority, store::db};
use weaver_contracts::{
    Error, MAX_CREDITS, Result, SourceAuthority, SourceIdentity, SourceRotation,
    SourceRotationOutcome, SourceRotationReceipt,
};

fn lookup(
    connection: &crate::persistence::driver::Connection,
    caller: &SourceIdentity,
    command: &SourceRotation,
    digest: &str,
    current: &SourceAuthority,
) -> Result<Option<SourceRotationReceipt>> {
    let record: Option<(String, String, String, String)> = crate::persistence::maybe(
        connection,
        "SELECT digest,proposer,command,receipt FROM source_rotations WHERE operation_id=?1",
        crate::persistence::params![command.operation_id.to_owned()],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
    )
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
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        let current = authority::current(&tx)?.ok_or(Error::Denied)?;
        if let Some(receipt) = lookup(&tx, caller, command, &digest, &current)? {
            return Ok(receipt);
        }
        authority::require(&tx, Some(caller))?;
        let used:bool=crate::persistence::one(&tx, "SELECT EXISTS(SELECT 1 FROM source_keys WHERE public_key_sha256=?1 OR certificate_sha256=?2)", crate::persistence::params![(command.next.public_key_sha256).to_owned(),(command.next.certificate_sha256).to_owned()], |r|r.get(0)).map_err(db)?;
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
        crate::persistence::exec(
            &tx,
            "INSERT INTO source_rotations VALUES(?1,?2,?3,?4,?5)",
            crate::persistence::params![
                (command.operation_id).to_owned(),
                (receipt.digest).to_owned(),
                (serde_json::to_string(caller)?).to_owned(),
                (serde_json::to_string(command)?).to_owned(),
                (serde_json::to_string(&receipt)?).to_owned()
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)?;
        Ok(receipt)
    }
}
