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
    pub fn evaluate(&mut self, input: &crate::Derivation) -> Result<Vec<String>, SourceError> {
        match input {
            crate::Derivation::Governor(cut) => self.derive(cut),
            crate::Derivation::FactImpact { root, dependencies } => {
                let input = crate::scheme_input::values::Input::new(&self.runtime);
                let root = input.record(vec![
                    ("root", input.text(root)?),
                    ("dependencies", input.edges(dependencies)?),
                ])?;
                let output =
                    linked::fact_impact(&self.runtime, &root).map_err(|_| SourceError::Scheme)?;
                crate::scheme::materialize(output)
            }
        }
    }
    pub fn derive(&mut self, cut: &crate::GovernorCut) -> Result<Vec<String>, SourceError> {
        let started = crate::host::governor_timing().then(std::time::Instant::now);
        let input = crate::scheme_input::values::Input::new(&self.runtime);
        let root = input.record(vec![
            ("nodes", input.strings(&cut.nodes)?),
            ("edges", input.edges(&cut.edges)?),
            ("complete", input.strings(&cut.complete)?),
            ("available", input.strings(&cut.available)?),
            ("pending", input.strings(&cut.pending)?),
            ("choice_arms", input.strings(&cut.choice_arms)?),
            ("choice_join", input.strings(&cut.choice_join)?),
            ("choice_result", input.strings(&cut.choice_result)?),
            ("choice_decided", input.strings(&cut.choice_decided)?),
            (
                "nested_selectors",
                input.vector(
                    cut.nested_selectors
                        .iter()
                        .map(|row| input.strings(row))
                        .collect::<Result<Vec<_>, _>>()?,
                )?,
            ),
            ("nested_results", input.edges(&cut.nested_results)?),
            ("nested_decisions", input.edges(&cut.nested_decisions)?),
        ])?;
        let input_done = started.map(|_| std::time::Instant::now());
        let output = linked::derive(&self.runtime, &root).map_err(|_| SourceError::Scheme)?;
        let ffi_done = started.map(|_| std::time::Instant::now());
        let result = crate::scheme::materialize(output);
        if let (Some(started), Some(input_done), Some(ffi_done)) = (started, input_done, ffi_done) {
            eprintln!(
                "weaver-governor-ffi input_ns={} call_ns={} output_ns={}",
                input_done.duration_since(started).as_nanos(),
                ffi_done.duration_since(input_done).as_nanos(),
                ffi_done.elapsed().as_nanos(),
            );
        }
        result
    }
    /// Compilation is inert preparation; the source lane independently binds
    /// this result to its retained original before any caller can claim it.
    pub fn compile(&mut self, original: &OwnedSource) -> Result<OwnedSource, SourceError> {
        self.compile_bound(original, None)
    }
    /// The source lane owns this monotonic token for the duration of capture.
    pub fn compile_cancellable(
        &mut self,
        original: &OwnedSource,
        cancel: &tokio_util::sync::CancellationToken,
    ) -> Result<OwnedSource, SourceError> {
        self.compile_bound(original, Some(cancel))
    }
    fn compile_bound(
        &mut self,
        original: &OwnedSource,
        shutdown: Option<&tokio_util::sync::CancellationToken>,
    ) -> Result<OwnedSource, SourceError> {
        let input = root_source(&self.runtime, original)?;
        let output =
            linked::capture(&self.runtime, &input, shutdown).map_err(|_| SourceError::Scheme)?;
        materialize_source(output)
    }
}
