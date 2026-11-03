// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later OR Apache-2.0

//! Compare an inert result to the host's independently retained original input.
use crate::{OwnedSource, SourceError};

/// Call-local original content, captured before invoking the approved producer.
/// This is neither producer authentication nor a publication/execution permit.
pub struct SourceExpectation {
    original: OwnedSource,
}

/// Owned data equal to the retained original content. Current source credentials,
/// Policy, fence and ledger checks remain mandatory at publication and use.
pub struct BoundSource {
    source: OwnedSource,
}

impl SourceExpectation {
    /// Snapshot the independently admitted input before entering Scheme. Never
    /// derive this expectation from the returned candidate or an agreeing alias.
    pub fn capture(original: &OwnedSource) -> Self {
        Self {
            original: original.clone(),
        }
    }

    /// Consume this call's expectation and reject even self-consistent changes.
    /// Array order and exact strings remain part of the original source image.
    pub fn bind(self, candidate: OwnedSource) -> Result<BoundSource, SourceError> {
        if candidate.data() != self.original.data() {
            return Err(SourceError::Binding);
        }
        Ok(BoundSource { source: candidate })
    }
}

impl BoundSource {
    /// Borrow original-bound data; no conversion to a live permit is provided.
    pub fn source(&self) -> &OwnedSource {
        &self.source
    }
}
