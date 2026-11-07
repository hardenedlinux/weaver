// SPDX-FileCopyrightText: 2026 hardenedlinux Linux Team and Contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later AND Apache-2.0

//! Reviewed Gerbil ABI leaf: no raw dereference, arbitrary export or graph input.
use gerbil_scheme::{
    GerbilRuntime, LinkedGerbilProgram, NativeError as GerbilError, RootedSchemeObject,
    SchemeScalar,
};
use std::cell::RefCell;
use tokio_util::sync::CancellationToken;

thread_local! {
    static CAPTURE_SHUTDOWN: RefCell<Option<CancellationToken>> = const { RefCell::new(None) };
}

// The linked Scheme call is synchronous on this same owner thread.
extern "C" fn capture_cancelled() -> i32 {
    i32::from(CAPTURE_SHUTDOWN.with(|slot| {
        slot.borrow()
            .as_ref()
            .is_some_and(CancellationToken::is_cancelled)
    }))
}
static CAPTURE_CANCEL_CALLBACK: extern "C" fn() -> i32 = capture_cancelled;

struct CaptureShutdown(Option<CancellationToken>);
impl Drop for CaptureShutdown {
    fn drop(&mut self) {
        CAPTURE_SHUTDOWN.with(|slot| slot.replace(self.0.take()));
    }
}
unsafe extern "C" {
    fn ___LNK_weaver__governance__program(
        ctx: *mut gerbil_scheme_sys::GerbilGlobalState,
    ) -> *mut gerbil_scheme_sys::GerbilModuleOrLink;
    fn weaver_governor_ready_steps_v1(root: i64) -> i64;
    fn weaver_hard_fact_impact_v1(root: i64) -> i64;
    fn weaver_capture_source_v1(root: i64) -> i64;
    fn weaver_governance_ready_v1(root: i64) -> i64;
    fn weaver_install_source_cancel_v1(callback: *const std::ffi::c_void);
}
pub(super) fn initialize() -> Result<GerbilRuntime, GerbilError> {
    // SAFETY: the build owner checks the fixed bridge, explicit application and
    // pinned Gerbil graph. The generated linker and graph have process lifetime;
    // the approved initializer must return normally and never finalize the VM.
    let program = unsafe { LinkedGerbilProgram::from_linker(___LNK_weaver__governance__program) };
    let runtime = GerbilRuntime::initialize_program(program)?;
    // SAFETY: this export is in the initialized graph and runs on its owner
    // thread. Scheme borrows the address of a process-lived typed callback slot.
    unsafe { weaver_install_source_cancel_v1(std::ptr::from_ref(&CAPTURE_CANCEL_CALLBACK).cast()) };
    Ok(runtime)
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
    shutdown: Option<&CancellationToken>,
) -> Result<RootedSchemeObject<'r>, GerbilError> {
    let _shutdown = CaptureShutdown(CAPTURE_SHUTDOWN.with(|slot| slot.replace(shutdown.cloned())));
    // SAFETY: fixed same-graph export uses Gerbil rooted-call, borrows the strong
    // input only synchronously, catches semantic declines and transfers one
    // fresh data/false root. It retains no Rust pointer and cannot finalize VM.
    let export = unsafe { runtime.bind_object_export(weaver_capture_source_v1) }?;
    export.call(input).into_result()
}

pub(super) fn derive<'r>(
    runtime: &'r GerbilRuntime,
    input: &RootedSchemeObject<'_>,
) -> Result<RootedSchemeObject<'r>, GerbilError> {
    // SAFETY: fixed linked rooted call transfers a fresh result. No VM state
    // or foreign pointer crosses the owner boundary.
    let export = unsafe { runtime.bind_object_export(weaver_governor_ready_steps_v1) }?;
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
