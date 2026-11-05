// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Burn each range before possible bytes; serialize the last guard and bounded native write.
use crate::{
    Ledger, StreamOwner,
    store::{db, integer},
    stream_custody::verify_owner,
    stream_state as state,
};
use weaver_contracts::{Error, MAX_BODY_BYTES, Result, WriteObservation};
use weaver_policy::StreamCheck;

/// Non-clonable consumed opportunity; crash or loss never creates a replacement token.
pub struct RangePermit {
    domains: weaver_contracts::DomainStamp,
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
        let tx =
            crate::persistence::begin_family(&mut self.connection, &owner.family).map_err(db)?;
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
        let tx =
            crate::persistence::begin_family(&mut self.connection, &owner.family).map_err(db)?;
        let row = active_range(&tx, &permit)?;
        crate::domains::require_stamp(&tx, &permit.family, &permit.domains)?;
        let contract = state::contract(&tx, &permit.family, &permit.node)?;
        let guarded = verify_owner(&tx, &self.session, owner).and_then(|()| {
            state::authorize_committed(
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
    tx: &crate::persistence::WriteScope<'_>,
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
    let previous:u64=crate::persistence::one(tx, "SELECT COUNT(*) FROM stream_messages WHERE family=?1 AND node=?2 AND ordinal<?3 AND state='complete'", crate::persistence::params![(owner.family).to_owned(),(owner.node).to_owned(),(row.ordinal as i64).to_owned()], |r|integer(r,0)).map_err(db)?;
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
    state::authorize_committed(
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
    let bytes:Vec<u8>=crate::persistence::one(tx, "SELECT substr(payload,?1,?2) FROM stream_messages WHERE family=?3 AND node=?4 AND message=?5", crate::persistence::params![(start as i64+1).to_owned(),((end-start) as i64).to_owned(),(owner.family).to_owned(),(owner.node).to_owned(),(message).to_owned()], |r|r.get(0)).map_err(db)?;
    if bytes.len() != end - start {
        return Err(Error::Conflict("immutable payload coverage"));
    }
    Ok(RangePermit {
        domains: crate::domains::stamp(tx, &owner.family)?,
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
fn persist_burn(tx: &crate::persistence::WriteScope<'_>, p: &RangePermit) -> Result<()> {
    crate::persistence::exec(
        tx,
        "INSERT INTO stream_ranges VALUES(?1,?2,?3,?4,?5,?6,NULL,'unknown')",
        crate::persistence::params![
            (p.family).to_owned(),
            (p.node).to_owned(),
            (p.message).to_owned(),
            (p.sequence as i64).to_owned(),
            (p.offset as i64).to_owned(),
            (p.bytes.len() as i64).to_owned()
        ],
    )
    .map_err(db)?;
    crate::persistence::exec(tx, "UPDATE stream_messages SET state='unknown',next_sequence=next_sequence+1 WHERE family=?1 AND node=?2 AND message=?3", crate::persistence::params![p.family.to_owned(),p.node.to_owned(),p.message.to_owned()])
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
fn active_range(
    tx: &crate::persistence::WriteScope<'_>,
    p: &RangePermit,
) -> Result<state::MessageRecord> {
    let row = state::record(tx, &p.family, &p.node, &p.message).map_err(|error| match error {
        Error::Conflict("message range progress changed") => {
            Error::Conflict("range consumption changed")
        }
        other => other,
    })?;
    let (range_state, offset, length, written): (String, u64, u64, Option<i64>) = crate::persistence::one(tx, "SELECT state,offset,length,written FROM stream_ranges WHERE family=?1 AND node=?2 AND message=?3 AND sequence=?4", crate::persistence::params![(p.family).to_owned(),(p.node).to_owned(),(p.message).to_owned(),(p.sequence as i64).to_owned()], |r| Ok((r.get(0)?, integer(r,1)?, integer(r,2)?, r.get(3)?))).map_err(db)?;
    if range_state != "unknown"
        || offset != p.offset
        || length != p.bytes.len() as u64
        || written.is_some()
        || row.next_sequence != p.sequence + 1
        || row.cursor != p.offset
        || row.state != "unknown"
    {
        return Err(Error::Conflict("range consumption changed"));
    }
    Ok(row)
}
fn record_no_send(tx: &crate::persistence::WriteScope<'_>, permit: &RangePermit) -> Result<()> {
    // This exact consumed token is destroyed without invoking the writer.
    crate::persistence::exec(tx, "UPDATE stream_ranges SET state='not_sent',written=0 WHERE family=?1 AND node=?2 AND message=?3 AND sequence=?4", crate::persistence::params![(permit.family).to_owned(),(permit.node).to_owned(),(permit.message).to_owned(),(permit.sequence as i64).to_owned()]).map_err(db)?;
    crate::persistence::exec(tx, "UPDATE stream_messages SET state=CASE WHEN cursor=0 THEN 'queued' ELSE 'active' END WHERE family=?1 AND node=?2 AND message=?3", crate::persistence::params![permit.family.to_owned(),permit.node.to_owned(),permit.message.to_owned()]).map_err(db)?;
    Ok(())
}
fn record_observation(
    tx: &crate::persistence::WriteScope<'_>,
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
    crate::persistence::exec(tx, "UPDATE stream_ranges SET state=?1,written=?2 WHERE family=?3 AND node=?4 AND message=?5 AND sequence=?6", crate::persistence::params![(range_state).to_owned(),(written).to_owned(),(permit.family).to_owned(),(permit.node).to_owned(),(permit.message).to_owned(),(permit.sequence as i64).to_owned()]).map_err(db)?;
    if observation == WriteObservation::Complete {
        let cursor = permit.offset + permit.bytes.len() as u64;
        let state = if cursor == row.proposal.payload_length {
            "complete"
        } else {
            "active"
        };
        crate::persistence::exec(tx, "UPDATE stream_messages SET cursor=?1,state=?2 WHERE family=?3 AND node=?4 AND message=?5", crate::persistence::params![(cursor as i64).to_owned(),(state).to_owned(),(permit.family).to_owned(),(permit.node).to_owned(),(permit.message).to_owned()]).map_err(db)?;
    }
    Ok(())
}
