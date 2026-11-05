// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Fixed compiled Scheme application on the existing thread-affine Gerbil owner.
use super::linked;
use crate::{OwnedSource, SourceError, materialize_source, root_source};
use gerbil_scheme::GerbilRuntime;

/// Neither this owner nor its Gerbil runtime is Send. Construct it on the tracked
/// blocking thread; no borrowed root/object crosses a queue or await.
pub struct SchemeCompiler {
    runtime: GerbilRuntime,
}
impl SchemeCompiler {
    /// Initialize the linked approved graph and require an installed producer.
    pub fn initialize() -> Result<Self, SourceError> {
        if weaver_policy_ffi::weaver_policy_abi_v1() != 0x0001_0000 {
            return Err(SourceError::Scheme);
        }
        let runtime = linked::initialize().map_err(|_| SourceError::Scheme)?;
        if !linked::ready(&runtime).map_err(|_| SourceError::Scheme)? {
            return Err(SourceError::Contract);
        }
        Ok(Self { runtime })
    }
    /// Compilation is inert preparation; the source lane independently binds
    /// this result to its retained original before any caller can claim it.
    pub fn compile(&mut self, original: &OwnedSource) -> Result<OwnedSource, SourceError> {
        let input = root_source(&self.runtime, original)?;
        let output = linked::capture(&self.runtime, &input).map_err(|_| SourceError::Scheme)?;
        materialize_source(output)
    }
}
