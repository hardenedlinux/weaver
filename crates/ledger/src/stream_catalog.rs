// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Immutable stream registration and one atomic source-budget hold per logical message.
use crate::persistence::WriteScope;
use crate::{Ledger, store::db, stream_state as state};
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
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
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
        let old: Option<String> = crate::persistence::maybe(
            &tx,
            "SELECT digest FROM streams WHERE family=?1 AND node=?2",
            crate::persistence::params![contract.family.to_owned(), contract.node.to_owned()],
            |r| r.get(0),
        )
        .map_err(db)?;
        if let Some(old) = old {
            if old != digest {
                return Err(Error::Conflict("original stream manifest changed"));
            }
            return Ok(());
        }
        crate::persistence::exec(
            &tx,
            "INSERT INTO streams(family,node,contract,digest) VALUES(?1,?2,?3,?4)",
            crate::persistence::params![
                (contract.family).to_owned(),
                (contract.node).to_owned(),
                (serde_json::to_string(contract)?).to_owned(),
                (digest).to_owned()
            ],
        )
        .map_err(db)?;
        tx.commit().map_err(db)
    }
    /// Atomically authorize, bind and reserve the original logical message exactly once.
    pub fn enqueue_message(&mut self, message: &StreamMessage) -> Result<MessageReceipt> {
        let binding = message.binding()?;
        let digest = binding.digest()?;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        if let Some(old) = state::receipt(&tx, &message.family, &message.node, &message.message)? {
            if old.digest != digest {
                return Err(Error::Conflict("original message changed"));
            }
            return Ok(old);
        }
        let ordinal = admit_message(&tx, message, &binding)?;
        reserve_message(&tx, message, &digest)?;
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
    tx: &WriteScope<'_>,
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
fn reserve_message(tx: &WriteScope<'_>, message: &StreamMessage, digest: &str) -> Result<()> {
    crate::execution_exposure::require_family(tx, &message.family)?;
    let kind: Option<String> = crate::persistence::maybe(
        tx,
        "SELECT kind FROM execution_claims WHERE family=?1 AND node=?2",
        crate::persistence::params![message.family.to_owned(), message.node.to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    if kind.is_some_and(|k| k != "stream") {
        return Err(Error::Conflict(
            "logical node already claimed by another execution kind",
        ));
    }
    crate::execution_exposure::retain(
        tx,
        crate::execution_exposure::ReservationClaim {
            family: &message.family,
            node: &message.node,
            kind: crate::execution_exposure::ClaimKind::Stream,
            member: &message.message,
            digest,
            ceiling: message.ceiling,
        },
    )?;
    let n = crate::persistence::exec(
        tx,
        "UPDATE tasks SET held=held+?1 WHERE family=?2 AND ?1<=budget-held",
        crate::persistence::params![
            (message.ceiling as i64).to_owned(),
            (message.family).to_owned()
        ],
    )
    .map_err(db)?;
    if n != 1 {
        return Err(Error::Conflict("shared stream budget exhausted"));
    }
    Ok(())
}
fn insert_message(
    tx: &WriteScope<'_>,
    message: &StreamMessage,
    binding: &MessageBinding,
    digest: &str,
    ordinal: usize,
) -> Result<()> {
    crate::persistence::exec(tx, "INSERT INTO stream_messages(family,node,message,ordinal,digest,proposal,reserved,auth_revision,auth_fence,state,cursor,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,'queued',0,?10)", crate::persistence::params![(message.family).to_owned(),(message.node).to_owned(),(message.message).to_owned(),(ordinal as i64).to_owned(),(digest).to_owned(),(serde_json::to_string(binding)?).to_owned(),(message.ceiling as i64).to_owned(),(message.revision as i64).to_owned(),(message.fence as i64).to_owned(),(message.payload.as_bytes()).to_owned()])
    .map_err(db)?;
    Ok(())
}
