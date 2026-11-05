// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Immutable publication candidates are qualified outside the deciding scope.
use crate::{
    persistence::{WriteScope, driver::Connection},
    reviewed_head,
    store::{db, integer},
    task_publication,
};
use std::borrow::Cow;
use weaver_contracts::{Error, ProviderPlan, Result};

#[cfg(feature = "commit-observer")]
thread_local! {
    static LOCKED_REVIEW: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Diagnostic reference for the observed server only.
#[cfg(feature = "commit-observer")]
pub fn use_locked_publication_review(locked: bool) {
    LOCKED_REVIEW.set(locked);
}

pub(crate) enum Prepared {
    Verified {
        review: reviewed_head::Prepared,
        birth: task_publication::Prepared,
    },
    #[cfg(feature = "commit-observer")]
    Locked,
}

pub(crate) fn prepare(connection: &Connection, family: &str) -> Result<Prepared> {
    #[cfg(feature = "commit-observer")]
    if LOCKED_REVIEW.get() {
        return Ok(Prepared::Locked);
    }
    Ok(Prepared::Verified {
        review: reviewed_head::prepare(connection)?,
        birth: task_publication::prepare(connection, family)?,
    })
}

impl Prepared {
    pub(crate) fn policy<'a>(
        &'a self,
        tx: &WriteScope<'_>,
        plan: &ProviderPlan,
        stale: &'static str,
    ) -> Result<Cow<'a, str>> {
        match self {
            Self::Verified { review, birth } => {
                let policy =
                    tx.provider_review(|| review.current(tx, plan.revision, plan.fence))?;
                tx.provider_birth(|| birth.require_current(tx, &plan.family))?;
                match policy {
                    Some(policy) => Ok(Cow::Borrowed(policy)),
                    None => tx
                        .provider_birth(|| current_source(tx, plan, stale))
                        .map(Cow::Owned),
                }
            }
            #[cfg(feature = "commit-observer")]
            Self::Locked => {
                tx.provider_review(|| reviewed_head::require(tx))?;
                tx.provider_birth(|| {
                    task_publication::require(tx, &plan.family)?;
                    current_source(tx, plan, stale)
                })
                .map(Cow::Owned)
            }
        }
    }
}

fn current_source(tx: &WriteScope<'_>, p: &ProviderPlan, stale: &'static str) -> Result<String> {
    let (revision, fence, source): (u64, u64, String) = crate::persistence::one_current(
        tx,
        "SELECT revision,fence,policy FROM authority WHERE singleton=1",
        (),
        |r| Ok((integer(r, 0)?, integer(r, 1)?, r.get(2)?)),
    )
    .map_err(db)?;
    if (p.revision, p.fence) != (revision, fence) {
        return Err(Error::Conflict(stale));
    }
    Ok(source)
}
