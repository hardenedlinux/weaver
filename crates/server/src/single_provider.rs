// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! One startup preparation, exact durable activation, and natural compiler retirement.
use crate::{
    grpc::Gateway, grpc_contracts::status, pb, session_workflow::SessionTopology,
    source_owner::SourceOwner,
};
use std::sync::{Arc, OnceLock};
use tokio::sync::{Mutex, OnceCell};
use tokio_util::sync::CancellationToken;
use tonic::Status;
use weaver_contracts::{
    FactFeed, PublicationOutcome, PublicationReceipt, SourceAuthority, SourceIdentity,
};
use weaver_governance::{BoundSource, OwnedSource};

#[derive(Default)]
pub(crate) struct SingleProvider {
    pub(crate) prepare: Mutex<()>,
    pub(crate) ready: OnceLock<Prepared>,
    retire: CancellationToken,
    retired: CancellationToken,
    live: CancellationToken,
    preopened: OnceCell<()>,
}

pub(crate) struct Prepared {
    pub(crate) producer: String,
    pub(crate) authority: SourceAuthority,
    wire_authority: Option<pb::SourceAuthorityView>,
    bound: BoundSource,
    operations: std::collections::BTreeMap<String, usize>,
    session: Option<Arc<SessionTopology>>,
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
        feed: Option<&FactFeed>,
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
        let session = feed
            .filter(|feed| !feed.workflow_path.is_empty())
            .map(|feed| SessionTopology::prepare(feed, bound.source().plans()).map(Arc::new))
            .transpose()?;
        let operations = bound
            .source()
            .plans()
            .iter()
            .enumerate()
            .map(|(index, plan)| (plan.node.clone(), index))
            .collect();
        Ok(Self {
            operations,
            producer: reply.producer.clone(),
            wire_authority: reply.authority.clone(),
            operation_id: publication.operation_id.clone(),
            digest,
            revision,
            fence: publication.fence,
            authority,
            bound,
            session,
        })
    }

    pub(crate) fn source(&self) -> &OwnedSource {
        self.bound.source()
    }

    /// Resolve inert original data only; final ledger/Cedar admission remains fresh.
    pub(crate) fn operation_plan(
        &self,
        family: &str,
        node: &str,
    ) -> Option<weaver_contracts::ProviderPlan> {
        if family != self.source().task().family {
            return None;
        }
        let mut plan = self
            .source()
            .plans()
            .get(*self.operations.get(node)?)?
            .clone();
        plan.revision = self.revision;
        plan.fence = self.fence;
        Some(plan)
    }

    pub(crate) fn session(&self) -> Option<&Arc<SessionTopology>> {
        self.session.as_ref()
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
    pub(crate) fn activate_governor(&self) {
        self.live.cancel();
    }

    pub(crate) fn activated(&self) -> bool {
        self.live.is_cancelled() || self.retirement_completed()
    }

    pub(crate) fn retirement_completed(&self) -> bool {
        self.retired.is_cancelled()
    }
}

impl Gateway {
    pub(super) async fn retire_prepared_provider(
        &self,
        source: &SourceOwner,
        caller: SourceIdentity,
        receipt: &PublicationReceipt,
    ) -> Result<(), Status> {
        let Some(prepared) = self
            .runtime
            .single_provider()
            .and_then(|lifecycle| lifecycle.ready.get())
        else {
            return Ok(());
        };
        if prepared.matches_commit(receipt)
            && prepared.authority.identity == caller
            && prepared.authority == source.authority(caller.clone()).await?
        {
            if let Some(feed) = self.runtime.fact_feed() {
                if let Some(lifecycle) = self.runtime.single_provider() {
                    if feed.workflow_dag
                        && governor_preopen_enabled()
                        && let Some(topology) = prepared.session()
                    {
                        lifecycle
                            .preopened
                            .get_or_init(|| async {
                                if let Ok(governor) = self.runtime.governor() {
                                    topology.preopen(&governor).await;
                                }
                            })
                            .await;
                        if prepared.authority != source.authority(caller).await? {
                            return Ok(());
                        }
                    }
                    lifecycle.activate_governor();
                    self.runtime.wake_session();
                }
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

fn governor_preopen_enabled() -> bool {
    std::env::var("WEAVER_TEST_GOVERNOR_PREOPEN").as_deref() == Ok("1")
        && std::env::var("WEAVER_TEST_GOVERNOR_RETAINED").as_deref() == Ok("1")
        && std::env::var("WEAVER_TEST_GOVERNOR_FULL_CUT").as_deref() != Ok("1")
        && std::env::var("WEAVER_TEST_GOVERNOR_NAMED_RESULT").as_deref() != Ok("1")
}
