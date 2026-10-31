//! Shared stream record reads and authoritative source/Policy joins.
use crate::store::{db, integer};
use rusqlite::{Connection, OptionalExtension, Transaction};
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
pub(crate) fn contract(c: &Connection, family: &str, node: &str) -> Result<StreamContract> {
    let body: String = c
        .query_row(
            "SELECT contract FROM streams WHERE family=?1 AND node=?2",
            [family, node],
            |r| r.get(0),
        )
        .map_err(db)?;
    Ok(serde_json::from_str(&body)?)
}
pub(crate) fn task(c: &Connection, family: &str) -> Result<Task> {
    let body: String = c
        .query_row("SELECT record FROM tasks WHERE family=?1", [family], |r| {
            r.get(0)
        })
        .map_err(db)?;
    Ok(serde_json::from_str(&body)?)
}
pub(crate) fn record(
    c: &Connection,
    family: &str,
    node: &str,
    message: &str,
) -> Result<MessageRecord> {
    let (p,state,cursor,revision,fence,ordinal,next_sequence):(String,String,u64,u64,u64,u64,u64)=c.query_row(
        "SELECT proposal,state,cursor,auth_revision,auth_fence,ordinal,next_sequence FROM stream_messages WHERE family=?1 AND node=?2 AND message=?3",
        [family,node,message],|r|Ok((r.get(0)?,r.get(1)?,integer(r,2)?,integer(r,3)?,integer(r,4)?,integer(r,5)?,integer(r,6)?))).map_err(db)?;
    Ok(MessageRecord {
        proposal: serde_json::from_str(&p)?,
        state,
        cursor,
        revision,
        fence,
        ordinal,
        next_sequence,
    })
}
pub(crate) fn authority(tx: &Transaction<'_>) -> Result<(u64, u64, String)> {
    crate::publication_barrier::require_resolved(tx)?;
    tx.query_row(
        "SELECT revision,fence,policy FROM authority WHERE singleton=1",
        [],
        |r| Ok((integer(r, 0)?, integer(r, 1)?, r.get(2)?)),
    )
    .map_err(db)
}
pub(crate) fn authorize(tx: &Transaction<'_>, check: StreamCheck<'_>) -> Result<()> {
    let (revision, fence, policy) = authority(tx)?;
    if revision != check.revision || fence != check.fence {
        return Err(Error::Conflict("stale stream authority"));
    }
    weaver_policy::authorize_stream(&policy, &task(tx, &check.contract.family)?, check)
}
pub(crate) fn receipt(
    c: &Connection,
    family: &str,
    node: &str,
    message: &str,
) -> Result<Option<MessageReceipt>> {
    c.query_row("SELECT digest,state,cursor,reserved FROM stream_messages WHERE family=?1 AND node=?2 AND message=?3",[family,node,message],|r|{
        let state:String=r.get(1)?;
        Ok(MessageReceipt{digest:r.get(0)?,cursor:integer(r,2)?,reserved:integer(r,3)?,state:match state.as_str(){
            "queued"=>MessageState::Queued,"active"=>MessageState::Active,"complete"=>MessageState::Complete,_=>MessageState::Unknown}})
    }).optional().map_err(db)
}
