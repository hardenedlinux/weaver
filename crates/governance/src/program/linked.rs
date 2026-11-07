// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Reviewed Gerbil ABI leaf: no raw dereference, arbitrary export or graph input.
use gerbil_scheme::{
    GerbilRuntime, LinkedGerbilProgram, NativeError as GerbilError, RootedSchemeObject,
    SchemeScalar,
};
unsafe extern "C" {
    fn ___LNK_weaver__governance__program(
        ctx: *mut gerbil_scheme_sys::GerbilGlobalState,
    ) -> *mut gerbil_scheme_sys::GerbilModuleOrLink;
    fn weaver_hard_fact_impact_v1(root: i64) -> i64;
    fn weaver_capture_source_v1(root: i64) -> i64;
    fn weaver_governance_ready_v1(root: i64) -> i64;
}
pub(super) fn initialize() -> Result<GerbilRuntime, GerbilError> {
    // SAFETY: the build owner checks the fixed bridge, explicit application and
    // pinned Gerbil graph. The generated linker and graph have process lifetime;
    // the approved initializer must return normally and never finalize the VM.
    let program = unsafe { LinkedGerbilProgram::from_linker(___LNK_weaver__governance__program) };
    GerbilRuntime::initialize_program(program)
}
pub(super) fn ready(runtime: &GerbilRuntime) -> Result<bool, GerbilError> {
    let input = runtime.nil_object()?;
    // SAFETY: fixed same-graph readiness export uses Gerbil rooted-call, borrows
    // input only for this call and transfers one fresh Boolean root; no reentry.
    let export = unsafe { runtime.bind_object_export(weaver_governance_ready_v1) }?;
    let output = export.call(&input).into_result()?;
    Ok(matches!(
        output.as_ref().scalar()?,
        SchemeScalar::Boolean(true)
    ))
}
pub(super) fn capture<'r>(
    runtime: &'r GerbilRuntime,
    input: &RootedSchemeObject<'_>,
) -> Result<RootedSchemeObject<'r>, GerbilError> {
    // SAFETY: fixed same-graph export uses Gerbil rooted-call, borrows the strong
    // input only synchronously, catches semantic declines and transfers one
    // fresh data/false root. It retains no Rust pointer and cannot finalize VM.
    let export = unsafe { runtime.bind_object_export(weaver_capture_source_v1) }?;
    export.call(input).into_result()
}

pub(super) fn fact_impact<'r>(
    runtime: &'r GerbilRuntime,
    input: &RootedSchemeObject<'_>,
) -> Result<RootedSchemeObject<'r>, GerbilError> {
    // SAFETY: fixed same-graph rooted call transfers one fresh result root.
    let export = unsafe { runtime.bind_object_export(weaver_hard_fact_impact_v1) }?;
    export.call(input).into_result()
}
