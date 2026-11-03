// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Shared stream record reads and authoritative source/Policy joins.
use crate::persistence::WriteScope;
use crate::store::{db, integer};
use weaver_contracts::{
    Error, MessageBinding, MessageReceipt, MessageState, Result, StreamContract, Task,
};
use weaver_policy::StreamCheck;

pub(crate) struct MessageRecord {
    pub proposal: MessageBinding,
    pub state: String,
    pub cursor: u64,
    pub revision: u64,
    pub fence: u64,
    pub ordinal: u64,
    pub next_sequence: u64,
}
pub(crate) fn contract(
    c: &crate::persistence::driver::Connection,
    family: &str,
    node: &str,
) -> Result<StreamContract> {
    let body: String = crate::persistence::one(
        c,
        "SELECT contract FROM streams WHERE family=?1 AND node=?2",
        crate::persistence::params![(family).to_owned(), (node).to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    Ok(serde_json::from_str(&body)?)
}
pub(crate) fn task(c: &crate::persistence::driver::Connection, family: &str) -> Result<Task> {
    let body: String = crate::persistence::one(
        c,
        "SELECT record FROM tasks WHERE family=?1",
        crate::persistence::params![(family).to_owned()],
        |r| r.get(0),
    )
    .map_err(db)?;
    Ok(serde_json::from_str(&body)?)
}
pub(crate) fn record(
    c: &crate::persistence::driver::Connection,
    family: &str,
    node: &str,
    message: &str,
) -> Result<MessageRecord> {
    let (p,state,cursor,revision,fence,ordinal,next_sequence):(String,String,u64,u64,u64,u64,u64)=crate::persistence::one(c, "SELECT proposal,state,cursor,auth_revision,auth_fence,ordinal,next_sequence FROM stream_messages WHERE family=?1 AND node=?2 AND message=?3", crate::persistence::params![(family).to_owned(),(node).to_owned(),(message).to_owned()], |r|Ok((r.get(0)?,r.get(1)?,integer(r,2)?,integer(r,3)?,integer(r,4)?,integer(r,5)?,integer(r,6)?))).map_err(db)?;
    let record = MessageRecord {
        proposal: serde_json::from_str(&p)?,
        state,
        cursor,
        revision,
        fence,
        ordinal,
        next_sequence,
    };
    crate::stream_progress::message(c, family, node, message, &record)?;
    Ok(record)
}
pub(crate) fn authority(tx: &WriteScope<'_>) -> Result<(u64, u64, String)> {
    crate::publication_barrier::require_resolved(tx)?;
    crate::persistence::one(
        tx,
        "SELECT revision,fence,policy FROM authority WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, integer(r, 1)?, r.get(2)?)),
    )
    .map_err(db)
}
pub(crate) fn authorize(tx: &WriteScope<'_>, check: StreamCheck<'_>) -> Result<()> {
    crate::task_publication::require(tx, &check.contract.family)?;
    let (revision, fence, policy) = authority(tx)?;
    if revision != check.revision || fence != check.fence {
        return Err(Error::Conflict("stale stream authority"));
    }
    weaver_policy::authorize_stream(&policy, &task(tx, &check.contract.family)?, check)
}
/// Existing-message effects require the original durable reservation and claim.
pub(crate) fn authorize_committed(tx: &WriteScope<'_>, check: StreamCheck<'_>) -> Result<()> {
    crate::execution_exposure::message(tx, check.message)?;
    authorize(tx, check)
}
pub(crate) fn receipt(
    c: &crate::persistence::driver::Connection,
    family: &str,
    node: &str,
    message: &str,
) -> Result<Option<MessageReceipt>> {
    crate::persistence::maybe(c, "SELECT digest,state,cursor,reserved FROM stream_messages WHERE family=?1 AND node=?2 AND message=?3", crate::persistence::params![(family).to_owned(),(node).to_owned(),(message).to_owned()], |r|{
        let state:String=r.get(1)?;
        Ok(MessageReceipt{digest:r.get(0)?,cursor:integer(r,2)?,reserved:integer(r,3)?,state:match state.as_str(){
            "queued"=>MessageState::Queued,"active"=>MessageState::Active,"complete"=>MessageState::Complete,_=>MessageState::Unknown}})
    }).map_err(db)
}
