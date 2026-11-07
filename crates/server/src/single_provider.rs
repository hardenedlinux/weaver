// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One startup preparation, exact durable activation, and natural compiler retirement.
use crate::{grpc::Gateway, grpc_contracts::status, pb, source_owner::SourceOwner};
use std::sync::OnceLock;
use tokio::sync::Mutex;
use tokio_util::sync::CancellationToken;
use tonic::Status;
use weaver_contracts::{
    ProviderPlan, PublicationOutcome, PublicationReceipt, SourceAuthority, SourceIdentity,
};
use weaver_governance::BoundSource;

#[derive(Default)]
pub(crate) struct SingleProvider {
    pub(crate) prepare: Mutex<()>,
    pub(crate) ready: OnceLock<Prepared>,
    retire: CancellationToken,
    retired: CancellationToken,
    live: CancellationToken,
}

pub(crate) struct Prepared {
    pub(crate) producer: String,
    pub(crate) authority: SourceAuthority,
    wire_authority: Option<pb::SourceAuthorityView>,
    bound: BoundSource,
    operation_id: String,
    digest: String,
    revision: u64,
    fence: u64,
}

impl Prepared {
    pub(crate) fn new(
        reply: &pb::CompiledSource,
        authority: SourceAuthority,
        bound: BoundSource,
    ) -> weaver_contracts::Result<Self> {
        let publication = bound.source().publication();
        let revision = match publication.expected_revision {
            Some(previous) => previous
                .checked_add(1)
                .filter(|next| *next <= weaver_contracts::MAX_CREDITS)
                .ok_or(weaver_contracts::Error::Invalid(
                    "publication revision exhausted",
                ))?,
            None => 0,
        };
        let digest = publication.digest()?;
        Ok(Self {
            producer: reply.producer.clone(),
            wire_authority: reply.authority.clone(),
            operation_id: publication.operation_id.clone(),
            digest,
            revision,
            fence: publication.fence,
            authority,
            bound,
        })
    }

    pub(crate) fn reply(&self) -> pb::CompiledSource {
        pb::CompiledSource {
            producer: self.producer.clone(),
            authority: self.wire_authority.clone(),
            artifact: Some(crate::source_artifact::artifact(&self.bound)),
        }
    }

    pub(crate) fn matches_commit(&self, receipt: &PublicationReceipt) -> bool {
        receipt.outcome == PublicationOutcome::Committed
            && receipt.operation_id == self.operation_id
            && receipt.digest == self.digest
            && receipt.revision == Some(self.revision)
            && receipt.fence == Some(self.fence)
    }
}

impl SingleProvider {
    pub(crate) fn request_retirement(&self) {
        self.retire.cancel();
    }

    pub(crate) fn retirement_requested(&self) -> bool {
        self.retire.is_cancelled()
    }

    pub(crate) fn acknowledge_retirement(&self) {
        self.retired.cancel();
    }

    pub(crate) async fn retired(&self) {
        self.retired.cancelled().await;
    }
}

impl Gateway {
    pub(crate) fn workflow_predecessor(
        &self,
        successor: &ProviderPlan,
    ) -> Result<Option<ProviderPlan>, Status> {
        let Some((feed, edge)) = self
            .runtime
            .fact_feed()
            .filter(|feed| feed.family == successor.family)
            .and_then(|feed| feed.workflow.as_ref().map(|edge| (feed, edge)))
            .filter(|(_, edge)| edge.successor == successor.node)
        else {
            return Ok(None);
        };
        let source = self
            .runtime
            .single_provider()
            .filter(|lifecycle| lifecycle.live.is_cancelled())
            .and_then(|lifecycle| lifecycle.ready.get())
            .map(|prepared| prepared.bound.source())
            .ok_or(Status::failed_precondition(
                "compiled workflow has not activated",
            ))?;
        let selection = &source.data().governance;
        if selection.family != feed.family
            || !selection.open_nodes.contains(&edge.predecessor)
            || !selection.open_nodes.contains(&successor.node)
        {
            return Err(Status::failed_precondition(
                "Governor workflow selection changed",
            ));
        }
        let admitted = |node: &str| {
            source
                .plans()
                .iter()
                .find(|plan| plan.family == selection.family && plan.node == node)
                .ok_or(Status::failed_precondition(
                    "compiled workflow plan missing",
                ))
        };
        if admitted(&successor.node)? != successor {
            return Err(Status::failed_precondition(
                "successor differs from compiled original",
            ));
        }
        Ok(Some(admitted(&edge.predecessor)?.clone()))
    }

    pub(super) async fn retire_prepared_provider(
        &self,
        source: &SourceOwner,
        caller: SourceIdentity,
        receipt: &PublicationReceipt,
    ) -> Result<(), Status> {
        let Some(lifecycle) = self.runtime.single_provider() else {
            return Ok(());
        };
        let Some(prepared) = lifecycle.ready.get() else {
            return Ok(());
        };
        if prepared.matches_commit(receipt)
            && prepared.authority.identity == caller
            && prepared.authority == source.authority(caller).await?
        {
            if self
                .runtime
                .fact_feed()
                .is_some_and(|feed| feed.workflow.is_some())
            {
                lifecycle.live.cancel();
                return Ok(());
            }
            self.runtime
                .retire_single_provider()
                .await
                .map_err(status)?;
        }
        Ok(())
    }
}
