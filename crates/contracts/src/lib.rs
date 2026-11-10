// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Canonical proposal boundary; records carry no execution authority.
mod delta_review;
pub use delta_review::{DeltaDisposition, DeltaReview, PublicationReviewContext, ReviewAuthority};
mod domains;
mod hard_fact;
pub use domains::{TaskAdmission, TaskAdmissionReceipt};
pub use hard_fact::{
    FactBarrier, FactFeed, FactIntent, FactResolution, FactWork, MAX_WORKFLOW_RESULT_BYTES,
    ProviderWorkflow, SESSION_CHOICE_SCHEMA, SESSION_DAG_SCHEMA, SESSION_NESTED_SCHEMA,
    SESSION_WORKFLOW_SCHEMA, WorkflowRoute, validate_session_choice, validate_session_dag,
    validate_session_selectors,
};
mod json;
pub use domains::{
    DomainBinding, DomainMigration, DomainMigrationReceipt, DomainStamp, DomainView,
};
mod metering;
mod model;
pub use metering::{
    MeteringApplication, MeteringDeployment, MeteringReceipt, MeteringTenant, ProviderQuote,
};
mod provider;
mod provider_catalog;
mod provider_routing;
pub use provider_routing::{
    ProviderOperationBinding, ProviderOperationScope, ProviderRoutingScope, RoutingCandidate,
    RoutingSelection,
};
mod provider_oauth;
pub use provider_catalog::{CatalogEntry, ProviderCatalog};
pub use provider_oauth::{
    ProviderOAuthDeployment, ProviderOAuthGrant, ProviderOAuthIssuerRotation, ProviderOAuthUse,
    oauth_hex,
};
mod provider_profile;
mod quotas;
pub use provider_profile::{
    ANTHROPIC_MESSAGES_SSE, CHAT_TEXT_SSE, ProviderProfile, ProviderProtocol, ProviderRequestFacts,
};
pub use quotas::{QuotaDeployment, QuotaKey};
mod publication;
mod publication_review;
mod source_authority;
pub use provider::{
    ProviderEvent, ProviderEventKind, ProviderPlan, ProviderReceipt, ProviderRoute, ProviderState,
};
pub use publication::{Publication, PublicationKey, PublicationOutcome, PublicationReceipt};
pub use publication_review::{AuthorityParent, PublicationReview};
pub use source_authority::{
    SourceAuthority, SourceIdentity, SourceRotation, SourceRotationOutcome, SourceRotationReceipt,
};
mod stream;
pub use json::{decode, decode_bounded};
pub use model::{
    Error, MAX_BODY_BYTES, MAX_CREDITS, Outcome, Proposal, Receipt, Result, Task, body_digest,
    identifier,
};
pub use stream::{
    MessageBinding, MessageReceipt, MessageRule, MessageState, StreamContract, StreamMessage,
    WriteObservation,
};

#[cfg(test)]
asp_rust::asp_rust_cargo_test_gate!(mode = deny, config = asp_rust::default_asp_rust_config());

mod qualified_delta;
pub use qualified_delta::{QualifiedDeltaCatalog, QualifiedDeltaEntry};
