//! One deciding projection for all retained execution kinds; never repairs authority.
use crate::persistence::WriteScope;
use crate::store::db;
use weaver_contracts::{Error, MessageBinding, Proposal, ProviderPlan, Result};

pub(crate) enum ClaimKind {
    Request,
    Stream,
    Provider,
}

pub(crate) struct ReservationClaim<'a> {
    pub family: &'a str,
    pub node: &'a str,
    pub kind: ClaimKind,
    pub member: &'a str,
    pub digest: &'a str,
    pub ceiling: u64,
}

/// Append the original member under the same transaction as its row and hold.
/// Only distinct stream messages may extend an existing logical node claim.
pub(crate) fn retain(tx: &WriteScope<'_>, claim: ReservationClaim<'_>) -> Result<()> {
    let kind = match claim.kind {
        ClaimKind::Request => "request",
        ClaimKind::Stream => "stream",
        ClaimKind::Provider => "provider",
    };
    let previous: Option<(String, String)> = crate::persistence::maybe(
        tx,
        "SELECT kind,reservations FROM execution_claims WHERE family=?1 AND node=?2",
        [claim.family, claim.node],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .map_err(db)?;
    let mut members = match &previous {
        Some((previous_kind, body)) if previous_kind == "stream" && kind == "stream" => {
            serde_json::from_str::<crate::exposure_manifest::Members>(body)?
        }
        Some(_) => return Err(Error::Conflict("logical reservation already claimed")),
        None => crate::exposure_manifest::Members::new(),
    };
    if members
        .insert(
            claim.member.to_owned(),
            crate::exposure_manifest::Member {
                digest: claim.digest.to_owned(),
                ceiling: claim.ceiling,
            },
        )
        .is_some()
    {
        return Err(Error::Conflict("logical reservation already claimed"));
    }
    let body = serde_json::to_string(&members)?;
    let changed = if previous.is_some() {
        crate::persistence::exec(
            tx,
            "UPDATE execution_claims SET reservations=?1 WHERE family=?2 AND node=?3",
            [body.as_str(), claim.family, claim.node],
        )
        .map_err(db)?
    } else {
        crate::persistence::exec(
            tx,
            "INSERT INTO execution_claims(family,node,kind,reservations) VALUES(?1,?2,?3,?4)",
            [claim.family, claim.node, kind, body.as_str()],
        )
        .map_err(db)?
    };
    if changed != 1 {
        return Err(Error::Conflict("logical reservation already claimed"));
    }
    Ok(())
}

/// Read every retained family reservation and its original kind under the writer.
/// Completion is observational: none of these execution paths authorizes refunds.
pub(crate) fn require_family(tx: &WriteScope<'_>, family: &str) -> Result<()> {
    crate::exposure_manifest::require(tx, family)
}

pub(crate) fn request(tx: &WriteScope<'_>, proposal: &Proposal) -> Result<()> {
    let matches: bool = crate::persistence::one(tx, "SELECT EXISTS(SELECT 1 FROM operations WHERE family=?1 AND node=?2 AND reserved=?3 AND digest=?4)", crate::persistence::params![(proposal.family).to_owned(),(proposal.node).to_owned(),(proposal.ceiling as i64).to_owned(),(proposal.digest()?).to_owned()], |row| row.get(0))
        .map_err(db)?;
    require(matches)?;
    require_family(tx, &proposal.family)
}

pub(crate) fn message(tx: &WriteScope<'_>, binding: &MessageBinding) -> Result<()> {
    let matches: bool = crate::persistence::one(tx, "SELECT EXISTS(SELECT 1 FROM stream_messages WHERE family=?1 AND node=?2 AND message=?3 AND reserved=?4 AND digest=?5)", crate::persistence::params![(binding.family).to_owned(),(binding.node).to_owned(),(binding.message).to_owned(),(binding.ceiling as i64).to_owned(),(binding.digest()?).to_owned()], |row| row.get(0)).map_err(db)?;
    require(matches)?;
    require_family(tx, &binding.family)
}

pub(crate) fn provider(tx: &WriteScope<'_>, plan: &ProviderPlan, digest: &str) -> Result<()> {
    let matches: bool = crate::persistence::one(tx, "SELECT EXISTS(SELECT 1 FROM provider_runs WHERE family=?1 AND node=?2 AND reserved=?3 AND digest=?4)", crate::persistence::params![(plan.family).to_owned(),(plan.node).to_owned(),(plan.ceiling as i64).to_owned(),(digest).to_owned()], |row| row.get(0)).map_err(db)?;
    require(matches)?;
    require_family(tx, &plan.family)
}

fn require(retained: bool) -> Result<()> {
    if retained {
        Ok(())
    } else {
        Err(Error::Conflict(
            "original claims or shared execution exposure not retained",
        ))
    }
}
