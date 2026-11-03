// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Canonical proposal boundary; records carry no execution authority.
mod delta_review;
pub use delta_review::{DeltaDisposition, DeltaReview, PublicationReviewContext, ReviewAuthority};
mod domains;
pub use domains::{TaskAdmission, TaskAdmissionReceipt};
mod json;
pub use domains::{
    DomainBinding, DomainMigration, DomainMigrationReceipt, DomainStamp, DomainView,
};
mod model;
mod provider;
mod provider_profile;
pub use provider_profile::{CHAT_TEXT_SSE, ProviderProfile, ProviderRequestFacts};
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
pub use json::decode;
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
