//! Exclusive software custody; reconnect never recreates an unknown write opportunity.
use crate::{
    Ledger,
    store::{db, integer},
    stream_state as state,
};
use weaver_contracts::{Error, Result};
use weaver_policy::StreamCheck;

/// Non-clonable local authority bound to one ledger handle, generation and destination.
pub struct StreamOwner {
    pub(crate) family: String,
    pub(crate) node: String,
    pub(crate) destination: String,
    pub(crate) session: String,
    pub(crate) generation: u64,
    pub(crate) fence: u64,
    revision: u64,
    connection_consumed: bool,
    domains: weaver_contracts::DomainStamp,
}
/// One explicit source/view request; this record carries no execution authority.
pub struct StreamClaim<'a> {
    pub family: &'a str,
    pub node: &'a str,
    pub destination: &'a str,
    pub revision: u64,
    pub fence: u64,
}
impl StreamOwner {
    /// Exact source-owned destination; this accessor carries no writable handle.
    pub fn destination(&self) -> &str {
        &self.destination
    }
}
impl Ledger {
    /// Acquire a new connection only at a known message boundary with current Cedar authority.
    pub fn claim_stream(&mut self, request: StreamClaim<'_>) -> Result<StreamOwner> {
        let StreamClaim {
            family,
            node,
            destination,
            revision: _,
            fence,
        } = request;
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        admit_custody(&tx, &request)?;
        let generation = advance_generation(&tx, &request, &self.session)?;
        let domains = crate::domains::stamp(&tx, family)?;
        tx.commit().map_err(db)?;
        Ok(StreamOwner {
            family: family.into(),
            node: node.into(),
            destination: destination.into(),
            session: self.session.clone(),
            generation,
            fence,
            revision: request.revision,
            connection_consumed: false,
            domains,
        })
    }
    /// Serialize a single native connection setup with current source authority and custody.
    pub fn connect_stream<T>(
        &mut self,
        owner: &mut StreamOwner,
        connect: impl FnOnce(&str) -> Result<T>,
    ) -> Result<T> {
        if owner.connection_consumed {
            return Err(Error::Conflict("connection opportunity already consumed"));
        }
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        verify_owner(&tx, &self.session, owner)?;
        authorize_connection(&tx, owner)?;
        owner.connection_consumed = true;
        let connection = connect(&owner.destination)?;
        tx.commit().map_err(db)?;
        Ok(connection)
    }
    /// Reauthorize an unsent original message; its identity, reservation and history remain intact.
    pub fn resume_message(
        &mut self,
        owner: &StreamOwner,
        message: &str,
        revision: u64,
        fence: u64,
    ) -> Result<()> {
        let tx = crate::persistence::begin(&mut self.connection).map_err(db)?;
        verify_owner(&tx, &self.session, owner)?;
        let row = state::record(&tx, &owner.family, &owner.node, message)?;
        if row.cursor != 0 || row.state != "queued" {
            return Err(Error::Conflict("only known unsent messages may resume"));
        }
        let contract = state::contract(&tx, &owner.family, &owner.node)?;
        state::authorize_committed(
            &tx,
            StreamCheck {
                contract: &contract,
                message: &row.proposal,
                action: "resumeMessage",
                offset: 0,
                length: row.proposal.payload_length,
                revision,
                fence,
            },
        )?;
        crate::persistence::exec(&tx, "UPDATE stream_messages SET auth_revision=?1,auth_fence=?2 WHERE family=?3 AND node=?4 AND message=?5", crate::persistence::params![(revision as i64).to_owned(),(fence as i64).to_owned(),(owner.family).to_owned(),(owner.node).to_owned(),(message).to_owned()]).map_err(db)?;
        tx.commit().map_err(db)
    }
}
fn authorize_connection(
    tx: &crate::persistence::WriteScope<'_>,
    owner: &StreamOwner,
) -> Result<()> {
    crate::stream_progress::stream(tx, &owner.family, &owner.node)?;
    let contract = state::contract(tx, &owner.family, &owner.node)?;
    let id:String=crate::persistence::one(tx, "SELECT message FROM stream_messages WHERE family=?1 AND node=?2 AND state!='complete' ORDER BY ordinal LIMIT 1", crate::persistence::params![owner.family.to_owned(),owner.node.to_owned()], |r|r.get(0)).map_err(db)?;
    let row = state::record(tx, &owner.family, &owner.node, &id)?;
    state::authorize_committed(
        tx,
        StreamCheck {
            contract: &contract,
            message: &row.proposal,
            action: "openStream",
            offset: 0,
            length: 0,
            revision: owner.revision,
            fence: owner.fence,
        },
    )
}
pub(crate) fn verify_owner(
    tx: &crate::persistence::WriteScope<'_>,
    session: &str,
    owner: &StreamOwner,
) -> Result<()> {
    if session != owner.session {
        return Err(Error::Conflict("foreign stream ledger handle"));
    }
    crate::domains::require_stamp(tx, &owner.family, &owner.domains)?;
    let (generation, holder, fence): (u64, String, u64) = crate::persistence::one(
        tx,
        "SELECT generation,owner,owner_fence FROM streams WHERE family=?1 AND node=?2",
        crate::persistence::params![owner.family.to_owned(), owner.node.to_owned()],
        |r| Ok((integer(r, 0)?, r.get(1)?, integer(r, 2)?)),
    )
    .map_err(db)?;
    let (_, current_fence, _) = state::authority(tx)?;
    if generation != owner.generation
        || holder != session
        || fence != owner.fence
        || fence != current_fence
    {
        return Err(Error::Conflict("stale stream custody"));
    }
    Ok(())
}

fn admit_custody(tx: &crate::persistence::WriteScope<'_>, request: &StreamClaim<'_>) -> Result<()> {
    let StreamClaim {
        family,
        node,
        destination,
        revision,
        fence,
    } = *request;
    crate::stream_progress::stream(tx, family, node)?;
    let contract = state::contract(tx, family, node)?;
    if contract.destination != destination {
        return Err(Error::Denied);
    }
    let blocked:i64=crate::persistence::one(tx, "SELECT COUNT(*) FROM stream_messages WHERE family=?1 AND node=?2 AND (state='unknown' OR (state!='complete' AND cursor>0))", crate::persistence::params![(family).to_owned(),(node).to_owned()], |r|r.get(0)).map_err(db)?;
    if blocked != 0 {
        return Err(Error::Conflict(
            "unknown or incomplete prefix blocks reconnect",
        ));
    }
    let id:String=crate::persistence::one(tx, "SELECT message FROM stream_messages WHERE family=?1 AND node=?2 AND state!='complete' ORDER BY ordinal LIMIT 1", crate::persistence::params![(family).to_owned(),(node).to_owned()], |r|r.get(0)).map_err(db)?;
    let message = state::record(tx, family, node, &id)?.proposal;
    state::authorize_committed(
        tx,
        StreamCheck {
            contract: &contract,
            message: &message,
            action: "openStream",
            offset: 0,
            length: 0,
            revision,
            fence,
        },
    )?;
    Ok(())
}
fn advance_generation(
    tx: &crate::persistence::WriteScope<'_>,
    request: &StreamClaim<'_>,
    session: &str,
) -> Result<u64> {
    let StreamClaim {
        family,
        node,
        fence,
        ..
    } = *request;
    let generation: u64 = crate::persistence::one(
        tx,
        "SELECT generation FROM streams WHERE family=?1 AND node=?2",
        crate::persistence::params![(family).to_owned(), (node).to_owned()],
        |r| integer(r, 0),
    )
    .map_err(db)?;
    let generation = generation
        .checked_add(1)
        .filter(|v| *v <= i64::MAX as u64)
        .ok_or(Error::Conflict("custody generation exhausted"))?;
    crate::persistence::exec(
        tx,
        "UPDATE streams SET generation=?1,owner=?2,owner_fence=?3 WHERE family=?4 AND node=?5",
        crate::persistence::params![
            (generation as i64).to_owned(),
            (session).to_owned(),
            (fence as i64).to_owned(),
            (family).to_owned(),
            (node).to_owned()
        ],
    )
    .map_err(db)?;
    Ok(generation)
}
