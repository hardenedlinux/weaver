// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Typed source-only preparation adapter. No request field installs a deployment key.
use crate::pb;
use tonic::Status;
use weaver_contracts::{
    AuthorityParent, DeltaDisposition, DeltaReview, PublicationKey, PublicationReview,
    PublicationReviewContext,
};
pub(crate) fn context(c: PublicationReviewContext) -> Result<pb::PublicationReviewContext, Status> {
    Ok(pb::PublicationReviewContext {
        publication: Some(pb::PublicationKey {
            operation_id: c.publication.operation_id,
            digest: c.publication.digest,
        }),
        parent: c.parent.map(|p| pb::AuthorityParent {
            revision: p.revision,
            fence: p.fence,
            policy_digest: p.policy_digest,
            schema_digest: p.schema_digest,
        }),
        reviewer: Some(pb::ReviewAuthority {
            audience: c.reviewer.audience,
            epoch: c.reviewer.epoch,
            public_key: c.reviewer.public_key,
            allow_expansion: c.reviewer.allow_expansion,
            qualified_catalog: c.reviewer.qualified_catalog,
        }),
        source: Some(crate::source_identity::view(c.source)?),
    })
}
pub(crate) fn evidence(e: pb::DeltaReview) -> Result<DeltaReview, Status> {
    let review = e.review.ok_or(Status::invalid_argument("review missing"))?;
    let key = review
        .publication
        .ok_or(Status::invalid_argument("review publication missing"))?;
    let disposition = match pb::DeltaDisposition::try_from(e.disposition) {
        Ok(pb::DeltaDisposition::Bootstrap) => DeltaDisposition::Bootstrap,
        Ok(pb::DeltaDisposition::NoExecutionGain) => DeltaDisposition::NoExecutionGain,
        Ok(pb::DeltaDisposition::ExplicitApproval) => DeltaDisposition::ExplicitApproval,
        _ => return Err(Status::invalid_argument("review disposition missing")),
    };
    let evidence = DeltaReview {
        review: PublicationReview {
            publication: PublicationKey {
                operation_id: key.operation_id,
                digest: key.digest,
            },
            parent: review.parent.map(|p| AuthorityParent {
                revision: p.revision,
                fence: p.fence,
                policy_digest: p.policy_digest,
                schema_digest: p.schema_digest,
            }),
            artifact: review.artifact,
        },
        audience: e.audience,
        reviewer_epoch: e.reviewer_epoch,
        source_epoch: e.source_epoch,
        source_identity_digest: e.source_identity_digest,
        disposition,
        delta: e.delta,
        signature: e.signature,
    };
    evidence
        .validate()
        .map_err(|_| Status::invalid_argument("review evidence bounds"))?;
    Ok(evidence)
}

pub(crate) fn evidence_message(e: DeltaReview) -> pb::DeltaReview {
    let disposition = match e.disposition {
        DeltaDisposition::Bootstrap => pb::DeltaDisposition::Bootstrap,
        DeltaDisposition::NoExecutionGain => pb::DeltaDisposition::NoExecutionGain,
        DeltaDisposition::ExplicitApproval => pb::DeltaDisposition::ExplicitApproval,
    };
    pb::DeltaReview {
        review: Some(pb::PublicationReview {
            publication: Some(pb::PublicationKey {
                operation_id: e.review.publication.operation_id,
                digest: e.review.publication.digest,
            }),
            parent: e.review.parent.map(|p| pb::AuthorityParent {
                revision: p.revision,
                fence: p.fence,
                policy_digest: p.policy_digest,
                schema_digest: p.schema_digest,
            }),
            artifact: e.review.artifact,
        }),
        audience: e.audience,
        reviewer_epoch: e.reviewer_epoch,
        source_epoch: e.source_epoch,
        source_identity_digest: e.source_identity_digest,
        disposition: disposition as i32,
        delta: e.delta,
        signature: e.signature,
    }
}
