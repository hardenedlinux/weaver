// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed commands between source admission and the ledger worker.
use std::sync::Arc;
use tokio::sync::{OwnedSemaphorePermit, oneshot};
use weaver_contracts::{
    FactBarrier, FactFeed, FactIntent, FactResolution, FactWork, Publication, PublicationKey,
    PublicationReceipt, Result, SourceAuthority, SourceIdentity, SourceRotation,
    SourceRotationReceipt, Task,
};
use weaver_ledger::FactPreparation;

type CatalogRead = Result<Option<(String, Vec<u8>)>>;

pub(super) enum Envelope {
    Source {
        caller: SourceIdentity,
        command: Box<Command>,
    },
    RoutingCut {
        family: String,
        node: String,
        reply: oneshot::Sender<Result<Option<weaver_ledger::ProviderOperationCut>>>,
        slot: OwnedSemaphorePermit,
    },
    RoutedTask {
        observed: Box<weaver_ledger::ProviderOperationCut>,
        task: Box<Task>,
        plan: Box<weaver_contracts::ProviderPlan>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },
}
pub(super) struct SourceDeployment {
    pub(super) review: Option<weaver_contracts::ReviewAuthority>,
    pub(super) metering: Option<weaver_contracts::MeteringDeployment>,
    pub(super) oauth: Option<weaver_contracts::ProviderOAuthDeployment>,
    pub(super) fact_feed: Option<FactFeed>,
    pub(super) session_wakeup: Option<Arc<tokio::sync::Notify>>,
}

pub(super) enum Command {
    RegisterOperationSource {
        scope: Box<weaver_contracts::ProviderOperationScope>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },

    InspectFact {
        reply: oneshot::Sender<Result<weaver_ledger::FactFeedState>>,
        slot: OwnedSemaphorePermit,
    },
    StageFact {
        intent: FactIntent,
        reply: oneshot::Sender<Result<FactBarrier>>,
        slot: OwnedSemaphorePermit,
    },
    PrepareFact {
        barrier: FactBarrier,
        reply: oneshot::Sender<Result<FactPreparation>>,
        slot: OwnedSemaphorePermit,
    },
    ResolveFact {
        work: FactWork,
        affected: Vec<String>,
        reply: oneshot::Sender<Result<FactResolution>>,
        slot: OwnedSemaphorePermit,
    },
    ChangeProviderOAuth {
        action: Box<crate::pb::provider_o_auth_change::Action>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },
    RotateMeter {
        tenant: String,
        issuer: String,
        expected: u64,
        next: SourceIdentity,
        reply: oneshot::Sender<Result<u64>>,
        slot: OwnedSemaphorePermit,
    },

    TerminalUsage {
        family: String,
        node: String,
        reply: oneshot::Sender<Result<weaver_contracts::MeteringReceipt>>,
        slot: OwnedSemaphorePermit,
    },

    ReadCatalog {
        reply: oneshot::Sender<CatalogRead>,
        slot: OwnedSemaphorePermit,
    },
    PublishCatalog {
        catalog: weaver_contracts::ProviderCatalog,
        reply: oneshot::Sender<Result<String>>,
        slot: OwnedSemaphorePermit,
    },
    ApplyMetering {
        evidence: Box<weaver_contracts::MeteringReceipt>,
        reply: oneshot::Sender<Result<weaver_contracts::MeteringApplication>>,
        slot: OwnedSemaphorePermit,
    },
    Original {
        task: Box<Task>,
        domains: weaver_contracts::DomainBinding,
        admission: weaver_contracts::TaskAdmission,
        publication: Option<PublicationKey>,
        reply: oneshot::Sender<Result<weaver_contracts::TaskAdmissionReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    RegisterDomain {
        task: Box<Task>,
        domains: weaver_contracts::DomainBinding,
        publication: Option<PublicationKey>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },
    Alias {
        family: String,
        origin: String,
        reply: oneshot::Sender<Result<weaver_contracts::DomainView>>,
        slot: OwnedSemaphorePermit,
    },
    Domains {
        family: String,
        reply: oneshot::Sender<Result<weaver_contracts::DomainView>>,
        slot: OwnedSemaphorePermit,
    },
    Migrate {
        change: weaver_contracts::DomainMigration,
        reply: oneshot::Sender<Result<weaver_contracts::DomainMigrationReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    Authority {
        reply: oneshot::Sender<Result<SourceAuthority>>,
        slot: OwnedSemaphorePermit,
    },
    Rotate {
        change: SourceRotation,
        reply: oneshot::Sender<Result<SourceRotationReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    Stage {
        change: Publication,
        reply: oneshot::Sender<Result<PublicationKey>>,
        slot: OwnedSemaphorePermit,
    },
    Register {
        task: Box<Task>,
        publication: Option<PublicationKey>,
        reply: oneshot::Sender<Result<()>>,
        slot: OwnedSemaphorePermit,
    },
    Publish {
        change: Publication,
        reply: oneshot::Sender<Result<PublicationReceipt>>,
        slot: OwnedSemaphorePermit,
    },
    StageReviewed {
        change: Publication,
        reply: oneshot::Sender<Result<PublicationKey>>,
        slot: OwnedSemaphorePermit,
    },
    ReviewContext {
        key: PublicationKey,
        reply: oneshot::Sender<Result<weaver_contracts::PublicationReviewContext>>,
        slot: OwnedSemaphorePermit,
    },
    RegisterReview {
        evidence: Box<weaver_contracts::DeltaReview>,
        reply: oneshot::Sender<Result<String>>,
        slot: OwnedSemaphorePermit,
    },
    Inspect {
        key: PublicationKey,
        reply: oneshot::Sender<Result<Option<PublicationReceipt>>>,
        slot: OwnedSemaphorePermit,
    },
}
