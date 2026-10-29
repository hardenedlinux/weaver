//! Burn each range before possible bytes; serialize the last guard and bounded native write.
use crate::{
    Ledger, StreamOwner,
    store::{db, integer},
    stream_custody::verify_owner,
    stream_state as state,
};
use rusqlite::TransactionBehavior;
use weaver_contracts::{Error, MAX_BODY_BYTES, Result, WriteObservation};
use weaver_policy::StreamCheck;

/// Non-clonable consumed opportunity; crash or loss never creates a replacement token.
pub struct RangePermit {
    session: String,
    generation: u64,
    family: String,
    node: String,
    message: String,
    sequence: u64,
    offset: u64,
    bytes: Vec<u8>,
}
impl Ledger {
    /// Persist an unknown range before returning any native write opportunity.
    pub fn consume_range(
        &mut self,
        owner: &StreamOwner,
        message: &str,
        max_bytes: usize,
    ) -> Result<RangePermit> {
        if max_bytes == 0 || max_bytes > MAX_BODY_BYTES {
            return Err(Error::Invalid("range bound"));
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        let permit = prepare_range(&tx, &self.session, owner, message, max_bytes)?;
        persist_burn(&tx, &permit)?;
        tx.commit().map_err(db)?;
        Ok(permit)
    }
    /// Join current authority with the exact bytes and hold the deciding lock through one write.
    /// The trusted executor must close/discard its buffers on any non-complete observation.
    pub fn write_range(
        &mut self,
        owner: &StreamOwner,
        permit: RangePermit,
        write: impl FnOnce(&[u8]) -> WriteObservation,
    ) -> Result<WriteObservation> {
        verify_binding(&self.session, owner, &permit)?;
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(db)?;
        let row = active_range(&tx, &permit)?;
        let contract = state::contract(&tx, &permit.family, &permit.node)?;
        let guarded = verify_owner(&tx, &self.session, owner).and_then(|()| {
            state::authorize(
                &tx,
                StreamCheck {
                    contract: &contract,
                    message: &row.proposal,
                    action: "writeRange",
                    offset: permit.offset,
                    length: permit.bytes.len() as u64,
                    revision: row.revision,
                    fence: row.fence,
                },
            )
        });
        if let Err(error) = guarded {
            record_no_send(&tx, &permit)?;
            tx.commit().map_err(db)?;
            return Err(error);
        }
        let observation = write(&permit.bytes);
        record_observation(&tx, &permit, &row, observation)?;
        // Completion does not authenticate usage and never refunds the original hold.
        tx.commit().map_err(db)?;
        Ok(observation)
    }
}

fn prepare_range(
    tx: &rusqlite::Transaction<'_>,
    session: &str,
    owner: &StreamOwner,
    message: &str,
    max_bytes: usize,
) -> Result<RangePermit> {
    verify_owner(tx, session, owner)?;
    let row = state::record(tx, &owner.family, &owner.node, message)?;
    if !matches!(row.state.as_str(), "queued" | "active") {
        return Err(Error::Conflict("message is complete or unknown"));
    }
    let previous:u64=tx.query_row("SELECT COUNT(*) FROM stream_messages WHERE family=?1 AND node=?2 AND ordinal<?3 AND state='complete'",rusqlite::params![owner.family,owner.node,row.ordinal as i64],|r|integer(r,0)).map_err(db)?;
    if previous != row.ordinal {
        return Err(Error::Conflict("prior logical message incomplete"));
    }
    let total = row.proposal.payload_length as usize;
    let start = row.cursor as usize;
    let end = (start + max_bytes).min(total);
    if start >= end {
        return Err(Error::Conflict("no remaining range"));
    }
    let contract = state::contract(tx, &owner.family, &owner.node)?;
    state::authorize(
        tx,
        StreamCheck {
            contract: &contract,
            message: &row.proposal,
            action: "writeRange",
            offset: row.cursor,
            length: (end - start) as u64,
            revision: row.revision,
            fence: row.fence,
        },
    )?;
    let sequence = row.next_sequence;
    if sequence >= i64::MAX as u64 {
        return Err(Error::Conflict("range sequence exhausted"));
    }
    let bytes:Vec<u8>=tx.query_row("SELECT substr(payload,?1,?2) FROM stream_messages WHERE family=?3 AND node=?4 AND message=?5",
            rusqlite::params![start as i64+1,(end-start) as i64,owner.family,owner.node,message],|r|r.get(0)).map_err(db)?;
    if bytes.len() != end - start {
        return Err(Error::Conflict("immutable payload coverage"));
    }
    Ok(RangePermit {
        session: session.to_owned(),
        generation: owner.generation,
        family: owner.family.clone(),
        node: owner.node.clone(),
        message: message.into(),
        sequence,
        offset: row.cursor,
        bytes,
    })
}
fn persist_burn(tx: &rusqlite::Transaction<'_>, p: &RangePermit) -> Result<()> {
    tx.execute(
        "INSERT INTO stream_ranges VALUES(?1,?2,?3,?4,?5,?6,NULL,'unknown')",
        rusqlite::params![
            p.family,
            p.node,
            p.message,
            p.sequence as i64,
            p.offset as i64,
            p.bytes.len() as i64
        ],
    )
    .map_err(db)?;
    tx.execute(
        "UPDATE stream_messages SET state='unknown',next_sequence=next_sequence+1 WHERE family=?1 AND node=?2 AND message=?3",
        [&p.family, &p.node, &p.message],
    )
    .map_err(db)?;
    Ok(())
}
fn verify_binding(session: &str, owner: &StreamOwner, permit: &RangePermit) -> Result<()> {
    if permit.session != session
        || permit.generation != owner.generation
        || permit.family != owner.family
        || permit.node != owner.node
    {
        return Err(Error::Conflict("foreign range permit"));
    }
    Ok(())
}
fn active_range(tx: &rusqlite::Transaction<'_>, p: &RangePermit) -> Result<state::MessageRecord> {
    let row = state::record(tx, &p.family, &p.node, &p.message)?;
    let range_state:String=tx.query_row("SELECT state FROM stream_ranges WHERE family=?1 AND node=?2 AND message=?3 AND sequence=?4",rusqlite::params![p.family,p.node,p.message,p.sequence as i64],|r|r.get(0)).map_err(db)?;
    if range_state != "unknown" || row.cursor != p.offset || row.state != "unknown" {
        return Err(Error::Conflict("range consumption changed"));
    }
    Ok(row)
}
fn record_no_send(tx: &rusqlite::Transaction<'_>, permit: &RangePermit) -> Result<()> {
    // This exact consumed token is destroyed without invoking the writer.
    tx.execute("UPDATE stream_ranges SET state='not_sent',written=0 WHERE family=?1 AND node=?2 AND message=?3 AND sequence=?4",rusqlite::params![permit.family,permit.node,permit.message,permit.sequence as i64]).map_err(db)?;
    tx.execute("UPDATE stream_messages SET state=CASE WHEN cursor=0 THEN 'queued' ELSE 'active' END WHERE family=?1 AND node=?2 AND message=?3",[&permit.family,&permit.node,&permit.message]).map_err(db)?;
    Ok(())
}
fn record_observation(
    tx: &rusqlite::Transaction<'_>,
    permit: &RangePermit,
    row: &state::MessageRecord,
    observation: WriteObservation,
) -> Result<()> {
    let (range_state, written) = match observation {
        WriteObservation::Complete => ("complete", Some(permit.bytes.len() as i64)),
        WriteObservation::Partial(n) if n < (permit.bytes.len() as u64) => {
            ("partial", Some(n as i64))
        }
        _ => ("unknown", None),
    };
    tx.execute("UPDATE stream_ranges SET state=?1,written=?2 WHERE family=?3 AND node=?4 AND message=?5 AND sequence=?6",rusqlite::params![range_state,written,permit.family,permit.node,permit.message,permit.sequence as i64]).map_err(db)?;
    if observation == WriteObservation::Complete {
        let cursor = permit.offset + permit.bytes.len() as u64;
        let state = if cursor == row.proposal.payload_length {
            "complete"
        } else {
            "active"
        };
        tx.execute("UPDATE stream_messages SET cursor=?1,state=?2 WHERE family=?3 AND node=?4 AND message=?5",rusqlite::params![cursor as i64,state,permit.family,permit.node,permit.message]).map_err(db)?;
    }
    Ok(())
}
