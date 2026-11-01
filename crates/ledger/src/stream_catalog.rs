//! Immutable stream registration and one atomic source-budget hold per logical message.
use crate::{Ledger, store::db, stream_state as state};
use rusqlite::{OptionalExtension, Transaction, TransactionBehavior};
use weaver_contracts::{
    Error, MessageBinding, MessageReceipt, Result, StreamContract, StreamMessage,
};
use weaver_policy::StreamCheck;

impl Ledger {
    /// Authenticate the service subject against the immutable original task owner.
    pub fn require_principal(&self, principal: &str, family: &str) -> Result<()> {
        if state::task(&self.connection, family)?.principal != principal {
            return Err(Error::Denied);
        }
        Ok(())
    }
    /// Resolve source-owned transport metadata; this record conveys no writable capability.
    pub fn stream_contract(&self, family: &str, node: &str) -> Result<StreamContract> {
        state::contract(&self.connection, family, node)
    }
    /// Publish or recover the exact source-owned stream manifest without sending.
    pub fn register_stream(&mut self, contract: &StreamContract) -> Result<()> {
        let digest = contract.digest()?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        let original = state::task(&tx, &contract.family)?;
        let minimum: u64 = contract.messages.iter().map(|r| r.cost_bound).sum();
        if !contract.matches(&original)
            || original
                .node_cost_bounds
                .get(&contract.node)
                .is_none_or(|cost| minimum > *cost)
        {
            return Err(Error::Denied);
        }
        let old: Option<String> = tx
            .query_row(
                "SELECT digest FROM streams WHERE family=?1 AND node=?2",
                [&contract.family, &contract.node],
                |r| r.get(0),
            )
            .optional()
            .map_err(db)?;
        if let Some(old) = old {
            if old != digest {
                return Err(Error::Conflict("original stream manifest changed"));
            }
            return Ok(());
        }
        tx.execute(
            "INSERT INTO streams(family,node,contract,digest) VALUES(?1,?2,?3,?4)",
            rusqlite::params![
                contract.family,
                contract.node,
                serde_json::to_string(contract)?,
                digest
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)
    }
    /// Atomically authorize, bind and reserve the original logical message exactly once.
    pub fn enqueue_message(&mut self, message: &StreamMessage) -> Result<MessageReceipt> {
        let binding = message.binding()?;
        let digest = binding.digest()?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        if let Some(old) = state::receipt(&tx, &message.family, &message.node, &message.message)? {
            if old.digest != digest {
                return Err(Error::Conflict("original message changed"));
            }
            return Ok(old);
        }
        let ordinal = admit_message(&tx, message, &binding)?;
        reserve_message(&tx, message)?;
        insert_message(&tx, message, &binding, &digest, ordinal)?;
        tx.commit().map_err(db)?;
        self.message_receipt(&message.family, &message.node, &message.message)?
            .ok_or(Error::Conflict("committed message missing"))
    }
    /// Observe the original outcome without issuing a new send capability.
    pub fn message_receipt(
        &self,
        family: &str,
        node: &str,
        message: &str,
    ) -> Result<Option<MessageReceipt>> {
        state::receipt(&self.connection, family, node, message)
    }
}

fn admit_message(
    tx: &Transaction<'_>,
    message: &StreamMessage,
    binding: &MessageBinding,
) -> Result<usize> {
    let contract = state::contract(tx, &message.family, &message.node)?;
    let (ordinal, rule) = contract
        .messages
        .iter()
        .enumerate()
        .find(|(_, r)| r.id == message.message)
        .ok_or(Error::Denied)?;
    if message.payload.len() as u64 > rule.max_bytes || message.ceiling < rule.cost_bound {
        return Err(Error::Denied);
    }
    state::authorize(
        tx,
        StreamCheck {
            contract: &contract,
            message: binding,
            action: "admitMessage",
            offset: 0,
            length: message.payload.len() as u64,
            revision: message.revision,
            fence: message.fence,
        },
    )?;
    Ok(ordinal)
}
fn reserve_message(tx: &Transaction<'_>, message: &StreamMessage) -> Result<()> {
    crate::execution_exposure::require_family(tx, &message.family)?;
    let kind: Option<String> = tx
        .query_row(
            "SELECT kind FROM execution_claims WHERE family=?1 AND node=?2",
            [&message.family, &message.node],
            |r| r.get(0),
        )
        .optional()
        .map_err(db)?;
    if kind.is_some_and(|k| k != "stream") {
        return Err(Error::Conflict("logical node already claimed by request"));
    }
    tx.execute(
        "INSERT OR IGNORE INTO execution_claims VALUES(?1,?2,'stream')",
        [&message.family, &message.node],
    )
    .map_err(db)?;
    let n = tx
        .execute(
            "UPDATE tasks SET held=held+?1 WHERE family=?2 AND ?1<=budget-held",
            rusqlite::params![message.ceiling as i64, message.family],
        )
        .map_err(db)?;
    if n != 1 {
        return Err(Error::Conflict("shared stream budget exhausted"));
    }
    Ok(())
}
fn insert_message(
    tx: &Transaction<'_>,
    message: &StreamMessage,
    binding: &MessageBinding,
    digest: &str,
    ordinal: usize,
) -> Result<()> {
    tx.execute(
        "INSERT INTO stream_messages(family,node,message,ordinal,digest,proposal,reserved,auth_revision,auth_fence,state,cursor,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,'queued',0,?10)",
        rusqlite::params![
            message.family,
            message.node,
            message.message,
            ordinal as i64,
            digest,
            serde_json::to_string(binding)?,
            message.ceiling as i64,
            message.revision as i64,
            message.fence as i64,
            message.payload.as_bytes()
        ],
    )
    .map_err(db)?;
    Ok(())
}
